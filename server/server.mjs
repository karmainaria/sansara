// Relic & Thread — AI appraiser agent
// Looks at photos of an object, identifies era / origin / maker from marks and style,
// estimates a fair price and writes it on-chain with its own Stellar key.
//
// Run:  node server/server.mjs      (config in server/.env)
// Needs: Node 18+, stellar CLI with keys "appraiser" and "seller" (demo seller).

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
loadEnv(path.join(ROOT, "server", ".env"));

const PORT = Number(process.env.PORT || 8787);
const CONTRACT_ID = process.env.CONTRACT_ID;
const NETWORK = process.env.STELLAR_NETWORK || "testnet";
const PAGES_BASE = (process.env.PAGES_BASE || "https://karmainaria.github.io/sansara").replace(/\/$/, "");
const IMG_DIR = path.join(ROOT, "docs", "img");
const GEMINI_KEY = process.env.GEMINI_API_KEY;
const ANTHROPIC_KEY = process.env.ANTHROPIC_API_KEY;
const PROVIDER = ANTHROPIC_KEY ? "anthropic" : GEMINI_KEY ? "gemini" : null;

fs.mkdirSync(IMG_DIR, { recursive: true });
if (!CONTRACT_ID) console.warn("! CONTRACT_ID missing in server/.env");
if (!PROVIDER) console.warn("! No AI key: add GEMINI_API_KEY or ANTHROPIC_API_KEY to server/.env");

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

async function askAI(images) {
  if (PROVIDER === "anthropic") {
    const content = images.map(img => ({
      type: "image",
      source: { type: "base64", media_type: img.mime, data: img.b64 },
    }));
    content.push({ type: "text", text: PROMPT });
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": ANTHROPIC_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: process.env.ANTHROPIC_MODEL || "claude-sonnet-5-5",
        max_tokens: 1500,
        messages: [{ role: "user", content }],
      }),
    });
    const j = await r.json();
    if (!r.ok) throw new Error("Claude API: " + (j.error?.message || r.status));
    return parseJSON(j.content.map(c => c.text || "").join(""));
  }
  if (PROVIDER === "gemini") {
    const model = process.env.GEMINI_MODEL || "gemini-2.5-flash";
    const parts = images.map(img => ({ inline_data: { mime_type: img.mime, data: img.b64 } }));
    parts.push({ text: PROMPT });
    const r = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_KEY}`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          contents: [{ role: "user", parts }],
          generationConfig: { responseMimeType: "application/json", temperature: 0.3 },
        }),
      }
    );
    const j = await r.json();
    if (!r.ok) throw new Error("Gemini API: " + (j.error?.message || r.status));
    return parseJSON(j.candidates?.[0]?.content?.parts?.map(p => p.text || "").join("") || "");
  }
  throw new Error("No AI key configured on the server");
}

function parseJSON(text) {
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) throw new Error("AI did not return JSON");
  return JSON.parse(m[0]);
}

// ---------------------------------------------------------------- prices

let rateCache = { eurPerXlm: Number(process.env.XLM_EUR) || 0.25, at: 0 };
async function eurPerXlm() {
  if (Date.now() - rateCache.at < 10 * 60e3) return rateCache.eurPerXlm;
  try {
    const r = await fetch("https://api.coingecko.com/api/v3/simple/price?ids=stellar&vs_currencies=eur");
    const j = await r.json();
    if (j?.stellar?.eur > 0) rateCache = { eurPerXlm: j.stellar.eur, at: Date.now() };
  } catch {}
  return rateCache.eurPerXlm;
}

// ---------------------------------------------------------------- stellar

function stellar(args) {
  return new Promise((resolve, reject) => {
    execFile("stellar", args, { maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) return reject(new Error((stderr || err.message).split("\n").filter(Boolean).slice(-6).join(" ")));
      resolve(stdout.trim());
    });
  });
}

function invoke(source, fn, params) {
  const args = ["contract", "invoke", "--id", CONTRACT_ID, "--network", NETWORK, "--source", source, "--", fn];
  for (const [k, v] of Object.entries(params)) args.push("--" + k, String(v));
  return stellar(args);
}

const parseOut = s => { try { return JSON.parse(s); } catch { return s.replace(/"/g, ""); } };

// one chain write at a time (keeps sequence numbers simple)
let chain = Promise.resolve();
const serial = fn => (chain = chain.then(fn, fn));

// ---------------------------------------------------------------- images & git

function saveImages(dataUrls) {
  const stamp = Date.now().toString(36);
  return dataUrls.slice(0, 4).map((d, i) => {
    const m = /^data:(image\/(jpeg|png|webp));base64,(.+)$/.exec(d || "");
    if (!m) throw new Error("Photos must be JPEG, PNG or WebP");
    const ext = m[2] === "jpeg" ? "jpg" : m[2];
    const name = `${stamp}-${i}.${ext}`;
    const buf = Buffer.from(m[3], "base64");
    if (buf.length > 3 * 1024 * 1024) throw new Error("Photo too large");
    fs.writeFileSync(path.join(IMG_DIR, name), buf);
    return `${PAGES_BASE}/img/${name}`;
  });
}

function readImages(imageUrl) {
  return imageUrl.split(/\s+/).filter(Boolean).map(u => {
    const name = path.basename(new URL(u).pathname);
    const file = path.join(IMG_DIR, name);
    if (!name || !fs.existsSync(file)) throw new Error("Photo not found on appraiser: " + name);
    const ext = path.extname(name).slice(1);
    return { mime: ext === "jpg" ? "image/jpeg" : "image/" + ext, b64: fs.readFileSync(file).toString("base64") };
  });
}

let gitQueue = Promise.resolve();
function publishImages() {
  gitQueue = gitQueue.then(() => new Promise(res => {
    execFile("bash", ["-c",
      `cd "${ROOT}" && git add docs/img && (git diff --cached --quiet || git commit -qm "Add listing photos") && (git pull -q --rebase || true) && git push -q`],
      err => { if (err) console.warn("git push failed:", err.message); res(); });
  }));
}

// ---------------------------------------------------------------- report

function toReport(a) {
  const lines = {
    era: a.era, origin: a.origin, maker: a.maker, marks: a.marks, materials: a.materials,
    condition: a.condition, story: a.story,
    value: `${Math.round(a.value_eur_low)}–${Math.round(a.value_eur_high)} EUR`,
    price_eur: Math.round(a.price_eur), confidence: a.confidence, reasoning: a.reasoning,
  };
  return Object.entries(lines)
    .map(([k, v]) => `${k}: ${String(v ?? "").replace(/\s+/g, " ").trim()}`)
    .join("\n")
    .slice(0, 2000);
}

const clip = (s, n) => String(s || "").replace(/\s+/g, " ").trim().slice(0, n);

// ---------------------------------------------------------------- http

const hits = new Map(); // simple rate limit per IP
function limited(ip) {
  const now = Date.now(), list = (hits.get(ip) || []).filter(t => now - t < 3600e3);
  list.push(now); hits.set(ip, list);
  return list.length > 30;
}

function send(res, code, obj) {
  res.writeHead(code, {
    "content-type": "application/json",
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "content-type",
    "access-control-allow-methods": "GET,POST,OPTIONS",
  });
  res.end(JSON.stringify(obj));
}

function body(req) {
  return new Promise((resolve, reject) => {
    let size = 0, chunks = [];
    req.on("data", c => { size += c.length; if (size > 16e6) { reject(new Error("Too large")); req.destroy(); } else chunks.push(c); });
    req.on("end", () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString() || "{}")); } catch { reject(new Error("Bad JSON")); } });
  });
}

http.createServer(async (req, res) => {
  if (req.method === "OPTIONS") return send(res, 204, {});
  const url = new URL(req.url, "http://x");
  const ip = req.headers["x-forwarded-for"]?.split(",")[0] || req.socket.remoteAddress;
  try {
    if (url.pathname === "/health")
      return send(res, 200, { ok: true, provider: PROVIDER, contract: CONTRACT_ID });

    if (url.pathname.startsWith("/img/")) {
      const file = path.join(IMG_DIR, path.basename(url.pathname));
      if (!fs.existsSync(file)) return send(res, 404, { error: "not found" });
      res.writeHead(200, { "content-type": "image/" + path.extname(file).slice(1).replace("jpg", "jpeg"), "access-control-allow-origin": "*" });
      return fs.createReadStream(file).pipe(res);
    }

    if (req.method !== "POST") return send(res, 404, { error: "not found" });
    if (limited(ip)) return send(res, 429, { error: "Too many requests, try again later" });
    const b = await body(req);

    // 1. photos -> files (published to GitHub Pages so they live on)
    if (url.pathname === "/upload") {
      const urls = saveImages(b.images || []);
      if (!urls.length) throw new Error("Add at least one photo");
      publishImages();
      return send(res, 200, { image_url: urls.join(" ") });
    }

    // 2. appraisal: AI looks at the photos and writes title, story and price on-chain
    if (url.pathname === "/appraise") {
      let id = b.id;
      if (!id) {
        // no wallet: list as the demo seller
        if (!b.image_url) throw new Error("image_url required");
        id = parseOut(await serial(() => invoke("seller", "submit_item", { seller: "seller", image_url: b.image_url })));
      }
      const item = parseOut(await invoke("appraiser", "get_item", { id }));
      if (item.status !== "Pending" && item.status !== 6) throw new Error("Item is not waiting for appraisal");

      const a = await askAI(readImages(item.image_url));
      const rate = await eurPerXlm();
      const priceEur = Math.max(1, Number(a.price_eur) || 0);
      const stroops = BigInt(Math.max(1, Math.round((priceEur / rate) * 1e7)));
      const category = String(a.category).toLowerCase() === "handmade" ? 1 : 0;

      await serial(() => invoke("appraiser", "appraise", {
        id,
        title: clip(a.title, 60) || "Untitled piece",
        description: clip(a.short_description, 220),
        category,
        price: stroops.toString(),
        report: toReport(a),
      }));
      return send(res, 200, { id: Number(id), appraisal: a, price_xlm: Number(stroops) / 1e7, eur_per_xlm: rate });
    }

    send(res, 404, { error: "not found" });
  } catch (e) {
    console.error(e);
    send(res, 400, { error: String(e.message || e).slice(0, 400) });
  }
}).listen(PORT, () => console.log(`AI appraiser on :${PORT} · ${PROVIDER || "NO AI KEY"} · contract ${CONTRACT_ID}`));

function loadEnv(file) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}
