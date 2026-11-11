// Relic & Thread — AI appraiser agent as a Netlify Function (runs 24/7, no Codespace needed).
// Routes:  POST /api/upload    photos -> Netlify Blobs, returns public URLs
//          POST /api/preview   AI appraises the uploaded photos; nothing is written on-chain yet.
//                              Modern factory-made pieces are rejected with 422 { rejected: true }.
//                              Returns { token, appraisal, price_xlm } (appraisal kept in Netlify Blobs)
//          POST /api/appraise  writes an appraisal on-chain:
//                                { token, id }  wallet already signed submit_item -> appraise(id) with the stored appraisal
//                                { token }      no wallet: demo seller lists the item, then appraise
//                                { id }         re-appraise an item stuck in Pending (runs the AI)
//                                { image_url }  AI + list as demo seller in one call
//          GET  /api/health
//          GET  /img/<name>     serves uploaded photos
// Env vars: CONTRACT_ID, APPRAISER_SECRET, SELLER_SECRET, GEMINI_API_KEY (preferred) or ANTHROPIC_API_KEY,
//           optional GEMINI_MODEL, ANTHROPIC_MODEL, RPC_URL, XLM_EUR

import { getStore } from "@netlify/blobs";
import {
  Account, Contract, Keypair, Networks, TransactionBuilder, BASE_FEE,
  nativeToScVal, scValToNative, rpc,
} from "@stellar/stellar-sdk";

export const config = { path: ["/api/*", "/img/*"] };

const env = k => (globalThis.Netlify?.env?.get?.(k)) ?? process.env[k];
const PASSPHRASE = Networks.TESTNET;
const sleep = ms => new Promise(r => setTimeout(r, ms));

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "content-type",
  "access-control-allow-methods": "GET,POST,OPTIONS",
};
const json = (status, obj) => new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", ...CORS } });

// ---------------------------------------------------------------- AI

const PROMPT = `You are an expert appraiser of antiques, vintage objects and handmade crafts.
Examine the photos carefully. Look for hallmarks, maker's marks, stamps, signatures, pottery and porcelain marks,
silver purity marks, factory labels, patent numbers, construction techniques, materials, wear and patina, and stylistic features.
Use these clues together with historical knowledge (design movements, manufacturers' active years, historical events,
changes in marking laws) to date the object as precisely as the evidence allows.
Classify the piece into exactly one "class":
 - "antique": about 100 or more years old.
 - "vintage": about 20 to 99 years old (factory-made is fine).
 - "handmade": made by hand by an independent maker (crafts, jewelry, ceramics, textiles...), any age.
 - "modern": under about 20 years old AND mass-produced / factory-made. Such pieces are not accepted.
If a piece is both old and handmade, prefer "antique" or "vintage" by age; use "handmade" for recent work by an independent maker.
Estimate a fair price for selling it online today in EUR, considering condition.
Be honest: if marks are unreadable or evidence is thin, say so and lower the confidence. Never invent a maker.

Reply with ONLY a JSON object, no markdown:
{
 "title": "short listing title, max 60 chars",
 "class": "antique" | "vintage" | "handmade" | "modern",
 "short_description": "1-2 sentences for the listing, max 220 chars",
 "era": "e.g. c. 1920-1930",
 "origin": "country / region, or 'unknown'",
 "maker": "maker or factory if identifiable from marks, else 'unknown'",
 "marks": "what marks/stamps/signatures you can see and what they mean, or 'none visible'",
 "materials": "main materials and techniques",
 "condition": "short condition assessment",
 "story": "2-3 sentences of historical context: what was happening when and where it was made, and why objects like this were produced",
 "value_eur_low": number,
 "value_eur_high": number,
 "price_eur": number,
 "confidence": "low" | "medium" | "high",
 "reasoning": "how you reached the date and price, max 300 chars"
}`;

function parseJSON(text) {
  const m = String(text).match(/\{[\s\S]*\}/);
  if (!m) throw new Error("AI did not return JSON");
  return JSON.parse(m[0]);
}

// Gemini is preferred whenever GEMINI_API_KEY is set; Claude is only a fallback.
async function askAI(images, budgetMs = 24000) {
  const anthropic = env("ANTHROPIC_API_KEY"), gemini = env("GEMINI_API_KEY");
  if (gemini) {
    const models = [...new Set([env("GEMINI_MODEL"), "gemini-2.5-flash", "gemini-2.5-flash-lite",
      "gemini-flash-latest", "gemini-flash-lite-latest"].filter(Boolean))];
    const parts = images.map(i => ({ inline_data: { mime_type: i.mime, data: i.b64 } }));
    parts.push({ text: PROMPT });
    let lastErr; const errs = [];
    const deadline = Date.now() + budgetMs; // Netlify stops the function at ~30 s
    for (const model of models) {
      for (let attempt = 0; attempt < 2; attempt++) {
        if (lastErr && errs.at(-1) !== lastErr.message) errs.push(lastErr.message);
        if (Date.now() > deadline - 3000) break;
        try {
          // "thinking" makes 2.5 models much slower; an appraisal doesn't need it
          const thinking = /2\.5/.test(model) ? { thinkingConfig: { thinkingBudget: 0 } } : {};
          const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${gemini}`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ contents: [{ role: "user", parts }], generationConfig: { responseMimeType: "application/json", temperature: 0.3, ...thinking } }),
            signal: AbortSignal.timeout(Math.min(12000, Math.max(3000, deadline - Date.now()))),
          });
          const j = await r.json();
          if (!r.ok) {
            lastErr = new Error(`Gemini (${model}): ` + (j.error?.message || r.status));
            if ([429, 500, 503].includes(r.status)) { await sleep(1200 * (attempt + 1)); continue; }
            break;
          }
          const text = j.candidates?.[0]?.content?.parts?.map(p => p.text || "").join("") || "";
          if (!text) { lastErr = new Error(`Gemini (${model}): empty answer (${j.candidates?.[0]?.finishReason || j.promptFeedback?.blockReason || "no reason"})`); break; }
          return parseJSON(text);
        } catch (e) { lastErr = new Error(`Gemini (${model}): ${e.message}`); await sleep(500); }
      }
    }
    if (lastErr && errs.at(-1) !== lastErr.message) errs.push(lastErr.message);
    throw new Error("All AI models are busy right now, please try again in a minute. " + errs.slice(-3).join(" | "));
  }
  if (anthropic) {
    const content = images.map(i => ({ type: "image", source: { type: "base64", media_type: i.mime, data: i.b64 } }));
    content.push({ type: "text", text: PROMPT });
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": anthropic, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: env("ANTHROPIC_MODEL") || "claude-sonnet-5-5", max_tokens: 1500, messages: [{ role: "user", content }] }),
    });
    const j = await r.json();
    if (!r.ok) throw new Error("Claude API: " + (j.error?.message || r.status));
    return parseJSON(j.content.map(c => c.text || "").join(""));
  }
  throw new Error("No AI key configured");
}

// ---------------------------------------------------------------- Stellar

const server = () => new rpc.Server(env("RPC_URL") || "https://soroban-testnet.stellar.org");
const contract = () => new Contract(env("CONTRACT_ID"));
const V = {
  u32: n => nativeToScVal(Number(n), { type: "u32" }),
  u64: n => nativeToScVal(BigInt(n), { type: "u64" }),
  i128: n => nativeToScVal(BigInt(n), { type: "i128" }),
  str: s => nativeToScVal(String(s), { type: "string" }),
  addr: a => nativeToScVal(a, { type: "address" }),
};

async function read(fn, ...args) {
  const src = new Account(Keypair.fromSecret(env("APPRAISER_SECRET")).publicKey(), "0");
  const tx = new TransactionBuilder(src, { fee: BASE_FEE, networkPassphrase: PASSPHRASE })
    .addOperation(contract().call(fn, ...args)).setTimeout(30).build();
  const sim = await server().simulateTransaction(tx);
  if (rpc.Api.isSimulationError(sim)) throw new Error(sim.error);
  return scValToNative(sim.result.retval);
}

async function invoke(secret, fn, ...args) {
  const kp = Keypair.fromSecret(secret);
  const s = server();
  const acc = await s.getAccount(kp.publicKey());
  let tx = new TransactionBuilder(acc, { fee: BASE_FEE, networkPassphrase: PASSPHRASE })
    .addOperation(contract().call(fn, ...args)).setTimeout(60).build();
  tx = await s.prepareTransaction(tx);
  tx.sign(kp);
  const sent = await s.sendTransaction(tx);
  if (sent.status === "ERROR") throw new Error(`${fn} rejected by the network`);
  for (let i = 0; i < 30; i++) {
    await sleep(1000);
    const r = await s.getTransaction(sent.hash);
    if (r.status === "SUCCESS") return { value: r.returnValue ? scValToNative(r.returnValue) : null, hash: sent.hash };
    if (r.status === "FAILED") throw new Error(`${fn} failed on-chain`);
  }
  throw new Error(`${fn} timed out`);
}

// ---------------------------------------------------------------- helpers

async function eurPerXlm() {
  try {
    const r = await fetch("https://api.coingecko.com/api/v3/simple/price?ids=stellar&vs_currencies=eur");
    const j = await r.json();
    if (j?.stellar?.eur > 0) return j.stellar.eur;
  } catch {}
  return Number(env("XLM_EUR")) || 0.25;
}

async function loadImages(imageUrl) {
  const urls = String(imageUrl).split(/\s+/).filter(Boolean).slice(0, 4);
  return Promise.all(urls.map(async u => {
    const r = await fetch(u);
    if (!r.ok) throw new Error("Could not load photo " + u);
    const mime = (r.headers.get("content-type") || "image/jpeg").split(";")[0];
    return { mime, b64: Buffer.from(await r.arrayBuffer()).toString("base64") };
  }));
}

const clip = (s, n) => String(s || "").replace(/\s+/g, " ").trim().slice(0, n);

function toReport(a) {
  const lines = {
    class: a.class, era: a.era, origin: a.origin, maker: a.maker, marks: a.marks, materials: a.materials,
    condition: a.condition, story: a.story,
    value: `${Math.round(a.value_eur_low)}–${Math.round(a.value_eur_high)} EUR`,
    price_eur: Math.round(a.price_eur), confidence: a.confidence, reasoning: a.reasoning,
  };
  return Object.entries(lines).map(([k, v]) => `${k}: ${clip(v, 600)}`).join("\n").slice(0, 2000);
}

const CLASSES = ["antique", "vintage", "handmade", "modern"];
const MODERN_MSG = "This looks like a modern factory-made piece. Relic & Thread is for antiques, vintage and handmade work.";
class Rejected extends Error {}

// Runs the AI on the photos and turns its answer into on-chain values. Throws if the AI fails.
async function runAppraisal(imageUrl, budgetMs) {
  const a = await askAI(await loadImages(imageUrl), budgetMs);
  if (!a || !a.title) throw new Error("The appraiser could not read these photos, please try again");
  a.class = String(a.class || a.category || "").toLowerCase().trim();
  if (!CLASSES.includes(a.class)) a.class = "vintage";
  if (a.class === "modern") throw new Rejected(MODERN_MSG);
  const rate = await eurPerXlm();
  const priceEur = Math.max(1, Number(a.price_eur) || 0);
  const stroops = String(Math.max(1, Math.round((priceEur / rate) * 1e7)));
  // on-chain category: 0 antique, 1 handmade, 2 vintage
  const category = { antique: 0, handmade: 1, vintage: 2 }[a.class];
  return { appraisal: a, rate, stroops, category };
}

// ---------------------------------------------------------------- handler

export default async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const url = new URL(req.url);
  const photos = getStore({ name: "photos", consistency: "strong" });
  const previews = getStore({ name: "previews", consistency: "strong" });

  try {
    if (url.pathname.startsWith("/img/")) {
      const name = url.pathname.split("/").pop();
      const blob = await photos.getWithMetadata(name, { type: "arrayBuffer" });
      if (!blob) return new Response("not found", { status: 404, headers: CORS });
      return new Response(blob.data, { headers: { "content-type": blob.metadata?.type || "image/jpeg", "cache-control": "public, max-age=31536000, immutable", ...CORS } });
    }

    if (url.pathname === "/api/health")
      return json(200, {
        ok: true,
        provider: env("GEMINI_API_KEY") ? "gemini" : env("ANTHROPIC_API_KEY") ? "anthropic" : null,
        contract: env("CONTRACT_ID") || null,
        appraiser: env("APPRAISER_SECRET") ? Keypair.fromSecret(env("APPRAISER_SECRET")).publicKey() : null,
      });

    if (req.method !== "POST") return json(404, { error: "not found" });
    const body = await req.json().catch(() => ({}));

    if (url.pathname === "/api/upload") {
      const list = (body.images || []).slice(0, 4);
      if (!list.length) throw new Error("Add at least one photo");
      const stamp = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
      const urls = [];
      for (let i = 0; i < list.length; i++) {
        const m = /^data:(image\/(jpeg|png|webp));base64,(.+)$/.exec(list[i] || "");
        if (!m) throw new Error("Photos must be JPEG, PNG or WebP");
        const buf = Buffer.from(m[3], "base64");
        if (buf.length > 3 * 1024 * 1024) throw new Error("Photo too large");
        const name = `${stamp}-${i}.${m[2] === "jpeg" ? "jpg" : m[2]}`;
        await photos.set(name, buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength), { metadata: { type: m[1] } });
        urls.push(`${url.origin}/img/${name}`);
      }
      return json(200, { image_url: urls.join(" ") });
    }

    if (url.pathname === "/api/preview") {
      if (!body.image_url) throw new Error("image_url required");
      const p = await runAppraisal(body.image_url);
      const token = Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
      await previews.setJSON(token, { ...p, image_url: body.image_url, created: Date.now() });
      return json(200, { token, appraisal: p.appraisal, price_xlm: Number(p.stroops) / 1e7, eur_per_xlm: p.rate });
    }

    if (url.pathname === "/api/appraise") {
      let id = body.id, imageUrl = body.image_url, p;
      if (body.token) {
        const saved = await previews.get(String(body.token), { type: "json" });
        if (!saved) throw new Error("Appraisal expired, please try again");
        p = saved; imageUrl = saved.image_url;
      }
      if (id) {
        const item = await read("get_item", V.u64(id));
        if (Number(item.status) !== 6) throw new Error("Item is not waiting for appraisal");
        if (p && item.image_url !== imageUrl) throw new Error("This appraisal belongs to other photos");
        imageUrl = item.image_url;
      }
      if (!imageUrl) throw new Error("image_url required");

      // AI first (unless already done in /preview), so nothing is written on-chain if it fails
      if (!p) p = await runAppraisal(imageUrl, id ? 18000 : 14000); // leave time for the on-chain writes
      const a = p.appraisal;

      if (!id) {
        // no wallet: list as the demo seller
        const seller = Keypair.fromSecret(env("SELLER_SECRET")).publicKey();
        id = (await invoke(env("SELLER_SECRET"), "submit_item", V.addr(seller), V.str(imageUrl))).value;
      }
      const tx = await invoke(env("APPRAISER_SECRET"), "appraise",
        V.u64(id), V.str(clip(a.title, 60) || "Untitled piece"), V.str(clip(a.short_description, 220)),
        V.u32(p.category), V.i128(BigInt(p.stroops)), V.str(toReport(a)));
      if (body.token) await previews.delete(String(body.token)).catch(() => {});

      return json(200, { id: Number(id), appraisal: a, price_xlm: Number(p.stroops) / 1e7, eur_per_xlm: p.rate, tx: tx.hash });
    }

    return json(404, { error: "not found" });
  } catch (e) {
    if (e instanceof Rejected) return json(422, { error: e.message, rejected: true });
    console.error(e);
    return json(400, { error: String(e.message || e).slice(0, 400) });
  }
};
