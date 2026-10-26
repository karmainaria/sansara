#!/usr/bin/env bash
# Step 6: move the AI appraiser to Netlify so it runs 24/7 (no Codespace needed)
# Usage: bash step6.sh [site-name]      default: relic-and-thread
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd /workspaces/sansara
set -e
SITE=${1:-relic-and-thread}
NL="npx -y netlify-cli@latest"

echo "== Writing the Netlify function =="
mkdir -p netlify/functions
cat > netlify/functions/api.mjs <<'EOF_RT'
// Relic & Thread — AI appraiser agent as a Netlify Function (runs 24/7, no Codespace needed).
// Routes:  POST /api/upload    photos -> Netlify Blobs, returns public URLs
//          POST /api/appraise  AI looks at the photos and writes title, story and price on-chain
//          GET  /api/health
//          GET  /img/<name>     serves uploaded photos
// Env vars: CONTRACT_ID, APPRAISER_SECRET, SELLER_SECRET, GEMINI_API_KEY or ANTHROPIC_API_KEY,
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
If it looks newly handmade (crafts, jewelry, ceramics by an independent maker), treat it as "handmade" and value it as such.
Estimate a fair price for selling it online today in EUR, considering condition.
Be honest: if marks are unreadable or evidence is thin, say so and lower the confidence. Never invent a maker.

Reply with ONLY a JSON object, no markdown:
{
 "title": "short listing title, max 60 chars",
 "category": "antique" or "handmade",
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

async function askAI(images) {
  const anthropic = env("ANTHROPIC_API_KEY"), gemini = env("GEMINI_API_KEY");
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
  if (gemini) {
    const models = [...new Set([env("GEMINI_MODEL"), "gemini-2.5-flash", "gemini-2.5-flash-lite",
      "gemini-flash-latest", "gemini-flash-lite-latest", "gemini-2.0-flash"].filter(Boolean))];
    const parts = images.map(i => ({ inline_data: { mime_type: i.mime, data: i.b64 } }));
    parts.push({ text: PROMPT });
    let lastErr;
    for (const model of models) {
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${gemini}`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ contents: [{ role: "user", parts }], generationConfig: { responseMimeType: "application/json", temperature: 0.3 } }),
          });
          const j = await r.json();
          if (!r.ok) {
            lastErr = new Error(`Gemini (${model}): ` + (j.error?.message || r.status));
            if ([429, 500, 503].includes(r.status)) { await sleep(1200 * (attempt + 1)); continue; }
            break;
          }
          return parseJSON(j.candidates?.[0]?.content?.parts?.map(p => p.text || "").join("") || "");
        } catch (e) { lastErr = e; await sleep(800); }
      }
    }
    throw new Error("All AI models are busy right now, please try again in a minute. " + (lastErr?.message || ""));
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
    era: a.era, origin: a.origin, maker: a.maker, marks: a.marks, materials: a.materials,
    condition: a.condition, story: a.story,
    value: `${Math.round(a.value_eur_low)}–${Math.round(a.value_eur_high)} EUR`,
    price_eur: Math.round(a.price_eur), confidence: a.confidence, reasoning: a.reasoning,
  };
  return Object.entries(lines).map(([k, v]) => `${k}: ${clip(v, 600)}`).join("\n").slice(0, 2000);
}

// ---------------------------------------------------------------- handler

export default async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const url = new URL(req.url);
  const photos = getStore({ name: "photos", consistency: "strong" });

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
        provider: env("ANTHROPIC_API_KEY") ? "anthropic" : env("GEMINI_API_KEY") ? "gemini" : null,
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

    if (url.pathname === "/api/appraise") {
      let id = body.id, imageUrl = body.image_url;
      if (id) {
        const item = await read("get_item", V.u64(id));
        if (Number(item.status) !== 6) throw new Error("Item is not waiting for appraisal");
        imageUrl = item.image_url;
      }
      if (!imageUrl) throw new Error("image_url required");

      // AI first, so nothing is written on-chain if it fails
      const a = await askAI(await loadImages(imageUrl));
      const rate = await eurPerXlm();
      const priceEur = Math.max(1, Number(a.price_eur) || 0);
      const stroops = BigInt(Math.max(1, Math.round((priceEur / rate) * 1e7)));
      const category = String(a.category).toLowerCase() === "handmade" ? 1 : 0;

      if (!id) {
        // no wallet: list as the demo seller
        const seller = Keypair.fromSecret(env("SELLER_SECRET")).publicKey();
        id = (await invoke(env("SELLER_SECRET"), "submit_item", V.addr(seller), V.str(imageUrl))).value;
      }
      const tx = await invoke(env("APPRAISER_SECRET"), "appraise",
        V.u64(id), V.str(clip(a.title, 60) || "Untitled piece"), V.str(clip(a.short_description, 220)),
        V.u32(category), V.i128(stroops), V.str(toReport(a)));

      return json(200, { id: Number(id), appraisal: a, price_xlm: Number(stroops) / 1e7, eur_per_xlm: rate, tx: tx.hash });
    }

    return json(404, { error: "not found" });
  } catch (e) {
    console.error(e);
    return json(400, { error: String(e.message || e).slice(0, 400) });
  }
};
EOF_RT
cat > netlify.toml <<'EOF_RT'
[build]
  publish = "docs"
  functions = "netlify/functions"

[functions]
  node_bundler = "esbuild"
EOF_RT
[ -f package.json ] || echo '{"name":"relic-and-thread","private":true,"type":"module"}' > package.json
grep -q '^node_modules' .gitignore 2>/dev/null || echo 'node_modules/' >> .gitignore
grep -q '^.netlify' .gitignore 2>/dev/null || echo '.netlify/' >> .gitignore

echo "== Installing packages =="
npm install --silent @stellar/stellar-sdk@14 @netlify/blobs

echo "== Pointing the website to Netlify =="
URL="https://$SITE.netlify.app/api"
for f in web/index.html docs/index.html; do sed -i "s|APPRAISER_URL: \"[^\"]*\"|APPRAISER_URL: \"$URL\"|" $f; done

echo "== Netlify login: open the link it prints, click Authorize, come back =="
$NL login

echo "== Creating site $SITE (press Enter if it asks for a team) =="
$NL sites:create --name "$SITE"

echo "== Saving secrets on Netlify (they are not printed) =="
set -a; . server/.env; set +a
[ -n "$GEMINI_API_KEY" ] && $NL env:set GEMINI_API_KEY "$GEMINI_API_KEY" >/dev/null
[ -n "$ANTHROPIC_API_KEY" ] && $NL env:set ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY" >/dev/null
$NL env:set GEMINI_MODEL "${GEMINI_MODEL:-gemini-2.5-flash}" >/dev/null
$NL env:set CONTRACT_ID "$CONTRACT_ID" >/dev/null
$NL env:set APPRAISER_SECRET "$(stellar keys show appraiser)" >/dev/null
$NL env:set SELLER_SECRET "$(stellar keys show seller)" >/dev/null
echo "secrets saved"

echo "== Deploying =="
$NL deploy --prod --dir docs --functions netlify/functions

echo "== Checking =="
sleep 3
curl -s "https://$SITE.netlify.app/api/health"; echo

git add -A && git commit -qm "AI appraiser on Netlify Functions (24/7), photos in Netlify Blobs" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push -q
echo
echo "App:       https://$SITE.netlify.app"
echo "Appraiser: $URL"
echo "STEP 6 DONE"
