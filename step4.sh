#!/usr/bin/env bash
# Step 4: phone app (installable PWA) + Albedo wallet for phones
cd /workspaces/sansara
set -e
# keep the live contract and appraiser URL from the current site
CID=$(grep -o 'CONTRACT_ID: "[A-Z0-9]*"' docs/index.html | head -1 | grep -o 'C[A-Z0-9]\{55\}')
AURL=$(grep -o 'APPRAISER_URL: "[^"]*"' docs/index.html | head -1 | sed 's/APPRAISER_URL: "//; s/"$//')
echo "contract: $CID"; echo "appraiser: $AURL"
[ -n "$CID" ] || { echo "Could not find CONTRACT_ID in docs/index.html"; exit 1; }
mkdir -p web docs
cat > web/index.html <<'EOF_RT'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#1e2421">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Relic &amp; Thread">
<link rel="manifest" href="manifest.webmanifest">
<link rel="apple-touch-icon" href="icon-180.png">
<link rel="icon" type="image/png" href="icon-192.png">
<title>Relic &amp; Thread</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:ital,wght@0,500;0,600;1,500&family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<script src="https://cdn.jsdelivr.net/npm/@stellar/stellar-sdk@14/dist/stellar-sdk.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@stellar/freighter-api@4/build/index.min.js"></script>
<style>
:root{
  --paper:#f4efe6; --card:#fbf8f2; --ink:#2a2420; --muted:#7a6e63; --line:#ddd3c4;
  --accent:#8c3b2a; --accent-ink:#fff; --gold:#a8823c; --ok:#3d6b45; --warn:#9a5b12;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    --paper:#1b1715; --card:#24201d; --ink:#efe7dc; --muted:#a89a8b; --line:#3a332d;
    --accent:#d0745c; --accent-ink:#1b1715; --gold:#d2ad66; --ok:#7fb487; --warn:#e0a456;
  }
}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.5 Inter,system-ui,sans-serif}
header{padding-top:env(safe-area-inset-top);position:sticky;top:0;z-index:5;background:var(--paper);border-bottom:1px solid var(--line)}
.bar{max-width:1100px;margin:auto;padding:14px 16px;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.logo{font:600 26px/1 "Cormorant Garamond",serif;letter-spacing:.5px;margin-right:auto}
.logo i{color:var(--accent);font-weight:500}
nav{display:flex;gap:4px}
nav button,.chip{background:none;border:1px solid transparent;color:var(--muted);padding:7px 12px;border-radius:999px;font:500 14px Inter;cursor:pointer}
nav button.on{color:var(--ink);border-color:var(--line);background:var(--card)}
.btn{background:var(--accent);color:var(--accent-ink);border:0;border-radius:10px;padding:10px 16px;font:600 14px Inter;cursor:pointer}
.btn.ghost{background:none;color:var(--ink);border:1px solid var(--line)}
.btn:disabled{opacity:.5;cursor:default}
main{max-width:1100px;margin:auto;padding:20px max(16px,env(safe-area-inset-right)) calc(60px + env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left))}
.hero{padding:18px 0 22px}
.hero h1{font:500 clamp(30px,6vw,48px)/1.05 "Cormorant Garamond",serif;margin:0 0 8px}
.hero p{color:var(--muted);margin:0;max-width:560px}
.filters{display:flex;gap:6px;margin:4px 0 18px;flex-wrap:wrap}
.chip{border-color:var(--line)}
.chip.on{background:var(--ink);color:var(--paper);border-color:var(--ink)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden;display:flex;flex-direction:column}
.card .img{aspect-ratio:4/3;background:var(--line) center/cover no-repeat}
.card .body{padding:12px 14px 14px;display:flex;flex-direction:column;gap:6px;flex:1}
.tag{font:600 11px Inter;letter-spacing:.08em;text-transform:uppercase;color:var(--gold)}
.card h3{font:600 21px/1.15 "Cormorant Garamond",serif;margin:0}
.card p{margin:0;color:var(--muted);font-size:13.5px}
.row{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-top:auto;padding-top:8px}
.price{font-weight:600}
.status{font:600 12px Inter;color:var(--muted)}
.status.Paid,.status.Disputed{color:var(--warn)} .status.Completed{color:var(--ok)}
form{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px;max-width:560px;display:grid;gap:12px}
label{display:grid;gap:5px;font-weight:500;font-size:13px}
input,textarea,select{font:15px Inter;padding:10px 12px;border:1px solid var(--line);border-radius:9px;background:var(--paper);color:var(--ink);width:100%}
textarea{min-height:90px;resize:vertical}
.two{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.empty{color:var(--muted);padding:30px 0}
.note{font-size:13px;color:var(--muted)}
.banner{background:var(--card);border:1px dashed var(--gold);border-radius:10px;padding:10px 14px;font-size:13px;margin-bottom:16px}
#toast{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);background:var(--ink);color:var(--paper);padding:10px 16px;border-radius:10px;font-size:14px;max-width:calc(100% - 32px);display:none;z-index:10}
.actions{display:flex;gap:6px;flex-wrap:wrap}
.sheet{position:fixed;inset:0;background:rgba(20,16,14,.45);display:flex;align-items:flex-end;justify-content:center;z-index:20;padding:16px;padding-bottom:calc(16px + env(safe-area-inset-bottom))}
.sheet[hidden]{display:none}
.sheet .panel{background:var(--card);color:var(--ink);border-radius:18px;padding:22px;width:100%;max-width:440px;display:grid;gap:12px;box-shadow:0 10px 40px rgba(0,0,0,.25)}
.sheet h3{font:600 26px/1.1 "Cormorant Garamond",serif;margin:0}
.sheet p{margin:0;color:var(--muted);font-size:14px}
.sheet .btn{width:100%;padding:14px;font-size:16px}
.walletbar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:-6px 0 16px}
.install{font-size:13px;color:var(--muted);border:1px dashed var(--line);border-radius:10px;padding:10px 12px;margin-bottom:16px}
.drop{border:1.5px dashed var(--line);border-radius:12px;padding:22px;text-align:center;color:var(--muted);cursor:pointer;background:var(--paper)}
.drop strong{color:var(--ink);display:block;font-size:16px;margin-bottom:4px}
.thumbs{display:flex;gap:8px;flex-wrap:wrap}
.thumbs img{width:76px;height:76px;object-fit:cover;border-radius:8px;border:1px solid var(--line)}
.appraisal{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px;max-width:560px;display:grid;gap:10px;margin-top:16px}
.appraisal h2{font:600 28px/1.1 "Cormorant Garamond",serif;margin:0}
.facts{display:grid;grid-template-columns:110px 1fr;gap:6px 12px;font-size:14px}
.facts dt{color:var(--muted)} .facts dd{margin:0}
.bigprice{font:600 30px/1 "Cormorant Garamond",serif;color:var(--accent)}
.pill{display:inline-block;font:600 11px Inter;letter-spacing:.06em;text-transform:uppercase;padding:3px 8px;border-radius:999px;border:1px solid var(--gold);color:var(--gold)}
details.ai{font-size:13px;color:var(--muted);margin-top:4px}
details.ai summary{cursor:pointer;color:var(--gold);font-weight:600}
details.ai p{margin:6px 0 0}
.working{display:flex;align-items:center;gap:10px;color:var(--muted)}
.dot{width:10px;height:10px;border-radius:50%;background:var(--gold);animation:pulse 1s infinite alternate}
@keyframes pulse{from{opacity:.3}to{opacity:1}}
@media (prefers-reduced-motion:reduce){.dot{animation:none}}
.actions .btn{padding:7px 11px;font-size:13px}
@media (max-width:520px){.two{grid-template-columns:1fr} .logo{font-size:22px}}
</style>
</head>
<body>
<header><div class="bar">
  <div class="logo">Relic <i>&amp;</i> Thread</div>
  <nav>
    <button data-tab="shop" class="on">Shop</button>
    <button data-tab="sell">Sell</button>
    <button data-tab="mine">My deals</button>
  </nav>
  <button class="btn" id="connect">Connect wallet</button>
</div></header>

<main>
  <section id="shop">
    <div class="hero">
      <h1>Old souls &amp; new hands.</h1>
      <p>Antiques and handmade pieces, paid in crypto on Stellar. Your payment waits safely in escrow until the piece arrives.</p>
    </div>
    <div id="installHint" class="install" hidden>Add Relic &amp; Thread to your home screen: tap <b>Share</b> → <b>Add to Home Screen</b>.</div>
    <div id="demoBanner" class="banner" hidden>Demo mode: add your CONTRACT_ID in the config to go live on testnet.</div>
    <div class="filters">
      <button class="chip on" data-cat="all">All</button>
      <button class="chip" data-cat="0">Antique</button>
      <button class="chip" data-cat="1">Handmade</button>
    </div>
    <div class="grid" id="grid"></div>
  </section>

  <section id="sell" hidden>
    <div class="hero"><h1>Just take photos.</h1><p>Our AI appraiser reads the marks and stamps, dates the piece, tells its story and sets a fair price on-chain. You don’t name a price; you can always withdraw the piece.</p></div>
    <form id="sellForm">
      <label class="drop" for="photos"><strong>Add 1–4 photos</strong>Whole piece, close-up of any marks, stamps or signature, and the underside.</label>
      <input id="photos" type="file" accept="image/*" multiple hidden>
      <div class="thumbs" id="thumbs"></div>
      <button class="btn" type="submit" id="appraiseBtn" disabled>Appraise with AI &amp; list</button>
      <div class="note" id="sellNote">Platform fee of 2.5% is taken only from completed sales.</div>
    </form>
    <div id="appraisal"></div>
  </section>

  <section id="mine" hidden>
    <div class="hero"><h1>My deals</h1><p>Your listings and purchases.</p></div>
    <div class="walletbar" id="walletbar"></div>
    <div class="grid" id="mineGrid"></div>
  </section>
</main>
<div class="sheet" id="sheet" hidden><div class="panel" id="sheetPanel"></div></div>
<div id="toast"></div>

<script>
// ================= CONFIG =================
const CONFIG = {
  CONTRACT_ID: "CABGIFZGNV4YPKYB2EDKWQXONJIAZEQHPZ25EWSX3WIXOD3QWOLEEMVT",
  NETWORK: "TESTNET",                 // or "PUBLIC"
  RPC_URL: "https://soroban-testnet.stellar.org",
  TOKEN_SYMBOL: "XLM",
  APPRAISER_URL: "",                  // AI appraiser server
  DECIMALS: 7,
};
// ==========================================

const S = window.StellarSdk;
const F = window.freighterApi;
const PASSPHRASE = S.Networks[CONFIG.NETWORK];
const server = new S.rpc.Server(CONFIG.RPC_URL);
const STATUS = ["Listed","Paid","Disputed","Completed","Refunded","Cancelled","Pending"];
const CAT = ["Antique","Handmade"];
const ERR = {1:"Item not found",2:"Invalid price",3:"Invalid category",4:"Not possible in this state",5:"Only the buyer can do this",6:"Only the seller can do this",7:"You can't buy your own item",8:"Invalid fee",9:"Not part of this deal",10:"Add at least one photo"};
let me = null, items = [], cat = "all";
const DEMO = !CONFIG.CONTRACT_ID;

document.querySelectorAll(".sym").forEach(e => e.textContent = CONFIG.TOKEN_SYMBOL);

// ---------- helpers ----------
const $ = s => document.querySelector(s);
function toast(msg, ms = 3500){ const t=$("#toast"); t.textContent=msg; t.style.display="block"; clearTimeout(t._h); t._h=setTimeout(()=>t.style.display="none", ms); }
const esc = s => String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const short = a => a ? a.slice(0,4)+"…"+a.slice(-4) : "";
function toUnits(str){ const [w,f=""]=String(str).split("."); return BigInt(w||0)*10n**BigInt(CONFIG.DECIMALS)+BigInt((f+"0".repeat(CONFIG.DECIMALS)).slice(0,CONFIG.DECIMALS)); }
function fromUnits(n){ n=BigInt(n); const d=10n**BigInt(CONFIG.DECIMALS); const f=(n%d).toString().padStart(CONFIG.DECIMALS,"0").replace(/0+$/,""); return (n/d).toString()+(f?"."+f:""); }
function niceError(e){ const m=String(e?.message||e); const c=m.match(/Error\(Contract, #(\d+)\)/); return c ? (ERR[c[1]]||m) : m.slice(0,160); }

const A = {
  addr: a => S.nativeToScVal(a, {type:"address"}),
  u64: n => S.nativeToScVal(BigInt(n), {type:"u64"}),
  u32: n => S.nativeToScVal(Number(n), {type:"u32"}),
  i128: n => S.nativeToScVal(BigInt(n), {type:"i128"}),
  str: s => S.nativeToScVal(String(s), {type:"string"}),
  bool: b => S.nativeToScVal(!!b),
};

// ---------- chain ----------
async function read(method, ...args){
  const acc = new S.Account(me || S.Keypair.random().publicKey(), "0");
  const tx = new S.TransactionBuilder(acc, {fee:"100", networkPassphrase:PASSPHRASE})
    .addOperation(new S.Contract(CONFIG.CONTRACT_ID).call(method, ...args)).setTimeout(30).build();
  const sim = await server.simulateTransaction(tx);
  if (S.rpc.Api.isSimulationError(sim)) throw new Error(sim.error);
  return S.scValToNative(sim.result.retval);
}

async function write(method, ...args){
  if (!me) await connect();
  let acc;
  try { acc = await server.getAccount(me); }
  catch { toast("New wallet — getting free test XLM…", 6000); await fund(); acc = await server.getAccount(me); }
  let tx = new S.TransactionBuilder(acc, {fee:S.BASE_FEE, networkPassphrase:PASSPHRASE})
    .addOperation(new S.Contract(CONFIG.CONTRACT_ID).call(method, ...args)).setTimeout(60).build();
  tx = await server.prepareTransaction(tx);
  const xdr = await signXdr(tx.toXDR());
  const sent = await server.sendTransaction(S.TransactionBuilder.fromXDR(xdr, PASSPHRASE));
  if (sent.status === "ERROR") throw new Error("Transaction rejected");
  for (let i = 0; i < 30; i++){
    await new Promise(r => setTimeout(r, 1500));
    const res = await server.getTransaction(sent.hash);
    if (res.status === "SUCCESS") return res.returnValue ? S.scValToNative(res.returnValue) : null;
    if (res.status === "FAILED") throw new Error("Transaction failed");
  }
  throw new Error("Timed out waiting for confirmation");
}

// ---------- wallets: Freighter (desktop) or Albedo (any browser, works on phones) ----------
let walletKind = null, albedo = null;
import("https://esm.sh/@albedo-link/intent@0.12.0").then(m => { albedo = m.default || m; }).catch(() => {});
try { const saved = JSON.parse(localStorage.getItem("rt_wallet") || "null"); if (saved) { me = saved.me; walletKind = saved.kind; } } catch {}

async function hasFreighter(){
  try { if (!F) return false; const c = await F.isConnected(); return !!(c?.isConnected ?? c); } catch { return false; }
}

// a bottom sheet with buttons; resolves with the chosen value (taps keep wallet pop-ups allowed on phones)
function sheet(title, text, buttons){
  return new Promise(resolve => {
    $("#sheetPanel").innerHTML = `<h3>${title}</h3>${text ? `<p>${text}</p>` : ""}` +
      buttons.map((b,i) => `<button class="btn ${b.ghost?"ghost":""}" data-i="${i}">${b.label}</button>`).join("");
    $("#sheet").hidden = false;
    $("#sheetPanel").onclick = e => {
      const i = e.target.closest("[data-i]")?.dataset.i; if (i == null) return;
      const b = buttons[i];
      if (b.run) { try { b.run(); } catch {} }
      $("#sheet").hidden = true; resolve(b.value);
    };
  });
}

function albedoReady(){ if (!albedo) throw new Error("Albedo is still loading, try again in a second"); return albedo; }

async function connect(){
  const desktop = await hasFreighter();
  let pending;
  const choice = await sheet("Connect a wallet", "Albedo works in any browser, including your phone. No app to install.", [
    { label: "Albedo (phone or computer)", value: "albedo",
      run: () => { pending = albedoReady().publicKey({ token: String(Date.now()) }); } },
    ...(desktop ? [{ label: "Freighter extension", value: "freighter", ghost: true }] : []),
    { label: "Cancel", value: null, ghost: true },
  ]);
  if (!choice) throw new Error("cancelled");
  if (choice === "albedo") {
    const r = await pending;
    me = r.pubkey;
  } else {
    const r = await F.requestAccess();
    if (r.error) { toast(r.error.message || "Wallet access denied"); throw new Error("denied"); }
    me = r.address || r;
  }
  walletKind = choice;
  try { localStorage.setItem("rt_wallet", JSON.stringify({ me, kind: walletKind })); } catch {}
  showWallet(); render();
}

async function signXdr(xdr){
  if (walletKind === "freighter") {
    const signed = await F.signTransaction(xdr, {networkPassphrase:PASSPHRASE, address:me});
    if (signed.error) throw new Error(signed.error.message || signed.error);
    return signed.signedTxXdr || signed;
  }
  let pending;
  const ok = await sheet("Confirm in Albedo", "A window opens where you approve this transaction.", [
    { label: "Sign with Albedo", value: true,
      run: () => { pending = albedoReady().tx({ xdr, network: CONFIG.NETWORK.toLowerCase(), pubkey: me }); } },
    { label: "Cancel", value: false, ghost: true },
  ]);
  if (!ok) throw new Error("Cancelled");
  const r = await pending;
  return r.signed_envelope_xdr;
}

async function fund(){
  if (CONFIG.NETWORK !== "TESTNET") throw new Error("Test XLM only exists on testnet");
  const r = await fetch("https://friendbot.stellar.org/?addr=" + encodeURIComponent(me));
  if (!r.ok && r.status !== 400) throw new Error("Friendbot is busy, try again");
}

function disconnect(){
  me = null; walletKind = null;
  try { localStorage.removeItem("rt_wallet"); } catch {}
  showWallet(); render();
}

function showWallet(){
  $("#connect").textContent = me ? short(me) : "Connect wallet";
  $("#walletbar").innerHTML = me
    ? `<span class="status">${walletKind === "albedo" ? "Albedo" : "Freighter"} · ${short(me)}</span>
       ${CONFIG.NETWORK==="TESTNET" ? `<button class="btn ghost" id="fundBtn">Get test XLM</button>` : ""}
       <button class="btn ghost" id="logoutBtn">Disconnect</button>`
    : "";
  const fb = $("#fundBtn"); if (fb) fb.onclick = async () => { fb.disabled = true; try { await fund(); toast("10,000 test XLM added"); } catch(e){ toast(e.message); } fb.disabled = false; };
  const lb = $("#logoutBtn"); if (lb) lb.onclick = disconnect;
}

// ---------- data ----------
const DEMO_ITEMS = [
  {id:3n,seller:"GDEMO…SELLER",buyer:null,title:"Art Deco glass vase, 1920s",description:"Hand-blown amber glass, signed on the base, no chips or cracks.",image_url:"https://images.unsplash.com/photo-1578749556568-bc2c40e68b61?w=800",category:0,price:4200000000n,status:0},
  {id:2n,seller:"GDEMO…SELLER",buyer:null,title:"Moonstone wire-wrap pendant",description:"Silver wire, wrapped by hand on a new moon. One of one.",image_url:"https://images.unsplash.com/photo-1515562141207-7a88fb7ce338?w=800",category:1,price:650000000n,status:0},
  {id:1n,seller:"GDEMO…SELLER",buyer:null,title:"Art nouveau mirror",description:"Carved oak frame, Paris c. 1905, original silvering.",image_url:"https://images.unsplash.com/photo-1618220179428-22790b461013?w=800",category:0,price:2900000000n,status:0},
];

async function load(){
  if (DEMO){ items = DEMO_ITEMS; $("#demoBanner").hidden = false; render(); return; }
  $("#grid").innerHTML = '<div class="empty">Loading…</div>';
  try {
    const all = []; let start = 0;
    while (true){
      const page = await read("get_items", A.u64(start), A.u32(50));
      all.push(...page);
      if (page.length < 50) break;
      start = Number(page[page.length-1].id) - 1;
      if (start <= 0) break;
    }
    items = all;
  } catch(e){ items = []; toast(niceError(e)); }
  render();
}

// ---------- ui ----------
function placeholder(it){
  const pal = Number(it.category) ? ["#cfd8e6","#6f7f9e","#f4f7fb"] : ["#c9a24a","#5e401b","#f1d58a"];
  const n = Number(it.id) % 3;
  const shape = n===0 ? "<ellipse cx='200' cy='170' rx='70' ry='85' fill='"+pal[2]+"' opacity='.5'/><rect x='175' y='70' width='50' height='30' rx='6' fill='"+pal[2]+"' opacity='.5'/>"
    : n===1 ? "<circle cx='200' cy='160' r='50' fill='"+pal[2]+"' opacity='.7'/><path d='M200 60V110' stroke='"+pal[2]+"' stroke-width='3'/>"
    : "<ellipse cx='200' cy='150' rx='65' ry='95' fill='"+pal[2]+"' opacity='.45'/>";
  const svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 300'><defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='"+pal[0]+"'/><stop offset='1' stop-color='"+pal[1]+"'/></linearGradient></defs><rect width='400' height='300' fill='url(#g)'/>"+shape+"</svg>";
  return "data:image/svg+xml," + encodeURIComponent(svg);
}

function parseReport(r){
  const o = {}; String(r||"").split("\n").forEach(l => { const i = l.indexOf(":"); if (i>0) o[l.slice(0,i).trim()] = l.slice(i+1).trim(); });
  return o;
}
const firstImg = u => String(u||"").split(/\s+/).filter(Boolean)[0];

function aiDetails(it){
  const r = parseReport(it.report); if (!r.era && !r.story) return "";
  const row = (k,v) => v && v!=="unknown" ? `<p><b>${k}:</b> ${esc(v)}</p>` : "";
  return `<details class="ai"><summary>AI appraisal · ${esc(r.confidence||"")} confidence</summary>
    ${row("Era",r.era)}${row("Origin",r.origin)}${row("Maker",r.maker)}${row("Marks",r.marks)}${row("Materials",r.materials)}
    ${row("Condition",r.condition)}${row("Story",r.story)}${row("Market value",r.value)}${row("Why this price",r.reasoning)}</details>`;
}

function card(it, mode){
  const st = STATUS[Number(it.status)];
  const isSeller = me && it.seller === me, isBuyer = me && it.buyer === me;
  let act = "";
  if (mode === "shop" && st === "Listed" && !isSeller) act = `<button class="btn" data-a="buy" data-id="${it.id}">Buy</button>`;
  if (mode === "mine"){
    if (isSeller && (st==="Listed"||st==="Pending"))  act += `<button class="btn ghost" data-a="cancel_listing" data-id="${it.id}">Cancel</button>`;
    if (isSeller && (st==="Paid"||st==="Disputed")) act += `<button class="btn ghost" data-a="refund" data-id="${it.id}">Refund</button>`;
    if (isBuyer && st==="Paid") act += `<button class="btn" data-a="confirm_receipt" data-id="${it.id}">Got it ✓</button>`;
    if ((isBuyer||isSeller) && st==="Paid") act += `<button class="btn ghost" data-a="open_dispute" data-id="${it.id}">Dispute</button>`;
  }
  const who = mode==="mine" ? `<span class="status">${isSeller?"selling":"bought"}</span>` : "";
  return `<article class="card">
    <div class="img" style="background-image:url('${esc(firstImg(it.image_url) || placeholder(it))}')"></div>
    <div class="body">
      <span class="tag">${CAT[Number(it.category)]||""} · #${it.id}</span>
      <h3>${esc(it.title || "Awaiting AI appraisal")}</h3>
      <p>${esc(it.description)}</p>
      ${aiDetails(it)}
      <div class="row"><span class="price">${st==="Pending" ? "—" : fromUnits(it.price)+" "+CONFIG.TOKEN_SYMBOL}${parseReport(it.report).price_eur ? ` <span class="status">≈ €${esc(parseReport(it.report).price_eur)}</span>`:""}</span><span class="status ${st}">${st==="Listed"?"":st}</span></div>
      ${act||who ? `<div class="row"><div class="actions">${act}</div>${who}</div>` : ""}
    </div></article>`;
}

function render(){
  const shop = items.filter(i => STATUS[Number(i.status)]==="Listed" && (cat==="all" || String(i.category)===cat));
  $("#grid").innerHTML = shop.length ? shop.map(i=>card(i,"shop")).join("") : '<div class="empty">Nothing here yet. Be the first to list a piece.</div>';
  const mine = me ? items.filter(i => i.seller===me || i.buyer===me) : [];
  $("#mineGrid").innerHTML = !me ? '<div class="empty">Connect your wallet to see your deals.</div>'
    : mine.length ? mine.map(i=>card(i,"mine")).join("") : '<div class="empty">No deals yet.</div>';
}

document.querySelectorAll("nav button").forEach(b => b.onclick = () => {
  document.querySelectorAll("nav button").forEach(x => x.classList.toggle("on", x===b));
  ["shop","sell","mine"].forEach(id => $("#"+id).hidden = id !== b.dataset.tab);
});
document.querySelectorAll(".chip").forEach(c => c.onclick = () => {
  cat = c.dataset.cat; document.querySelectorAll(".chip").forEach(x=>x.classList.toggle("on",x===c)); render();
});
$("#connect").onclick = () => me ? document.querySelector('nav [data-tab="mine"]').click() : connect().catch(()=>{});

document.body.addEventListener("click", async e => {
  const b = e.target.closest("[data-a]"); if (!b) return;
  if (DEMO) return toast("Demo mode — deploy the contract to trade for real");
  const a = b.dataset.a, id = b.dataset.id;
  b.disabled = true;
  try {
    if (!me) await connect();
    await write(a, A.addr(me), A.u64(id));
    toast({buy:"Paid! Funds are held in escrow.",confirm_receipt:"Done — seller has been paid.",refund:"Refunded.",cancel_listing:"Listing cancelled.",open_dispute:"Dispute opened."}[a]);
    await load();
  } catch(err){ toast(niceError(err)); b.disabled = false; }
});

let photos = [];
function shrink(file){
  return new Promise((resolve, reject) => {
    const img = new Image(), url = URL.createObjectURL(file);
    img.onload = () => {
      const k = Math.min(1, 1280 / Math.max(img.width, img.height));
      const c = document.createElement("canvas"); c.width = Math.round(img.width*k); c.height = Math.round(img.height*k);
      c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
      URL.revokeObjectURL(url); resolve(c.toDataURL("image/jpeg", 0.85));
    };
    img.onerror = () => reject(new Error("Could not read that photo"));
    img.src = url;
  });
}
$("#photos").onchange = async e => {
  try {
    const add = await Promise.all([...e.target.files].map(shrink));
    photos = [...photos, ...add].slice(0, 4);
  } catch(err){ toast(err.message); }
  $("#thumbs").innerHTML = photos.map(p => `<img src="${p}" alt="Photo of the piece">`).join("");
  $("#appraiseBtn").disabled = !photos.length;
  e.target.value = "";
};

async function api(path, body){
  if (!CONFIG.APPRAISER_URL) throw new Error("The AI appraiser is offline right now");
  const r = await fetch(CONFIG.APPRAISER_URL.replace(/\/$/,"") + path, {method:"POST", headers:{"content-type":"application/json"}, body:JSON.stringify(body)});
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || "Appraiser error " + r.status);
  return j;
}

function showAppraisal(res){
  const a = res.appraisal, f = (k,v) => v && v!=="unknown" ? `<dt>${k}</dt><dd>${esc(v)}</dd>` : "";
  $("#appraisal").innerHTML = `<div class="appraisal">
    <span class="pill">${a.category==="handmade"?"Handmade":"Antique"} · ${esc(a.confidence)} confidence · #${res.id}</span>
    <h2>${esc(a.title)}</h2>
    <div class="bigprice">${res.price_xlm.toFixed(2)} XLM <span class="status">≈ €${Math.round(a.price_eur)}</span></div>
    <p class="note">${esc(a.short_description)}</p>
    <dl class="facts">${f("Era",a.era)}${f("Origin",a.origin)}${f("Maker",a.maker)}${f("Marks",a.marks)}${f("Materials",a.materials)}${f("Condition",a.condition)}${f("Market value",`€${Math.round(a.value_eur_low)}–${Math.round(a.value_eur_high)}`)}</dl>
    <p>${esc(a.story)}</p>
    <p class="note">${esc(a.reasoning)}</p>
    <div class="actions"><button class="btn" type="button" onclick="document.querySelector('nav [data-tab=shop]').click()">See it in the shop</button></div>
  </div>`;
}

$("#sellForm").onsubmit = async e => {
  e.preventDefault();
  if (DEMO) return toast("Demo mode — deploy the contract to list for real");
  const btn = $("#appraiseBtn"); btn.disabled = true;
  const step = t => $("#appraisal").innerHTML = `<div class="appraisal"><div class="working"><span class="dot"></span>${t}</div></div>`;
  try {
    step("Uploading photos…");
    const { image_url } = await api("/upload", { images: photos });
    let id = null;
    if (me) { step("Confirm the listing in your wallet…"); id = await write("submit_item", A.addr(me), A.str(image_url)); }
    step("The appraiser is reading the marks and dating your piece… (about 20 seconds)");
    const res = await api("/appraise", id ? { id: Number(id) } : { image_url });
    showAppraisal(res);
    photos = []; $("#thumbs").innerHTML = "";
    if (!me) $("#sellNote").textContent = "Listed with the demo seller account. Connect a wallet to list under your own name.";
    load();
  } catch(err){ $("#appraisal").innerHTML = ""; toast(niceError(err), 6000); }
  btn.disabled = !photos.length;
};

showWallet();
const standalone = window.matchMedia("(display-mode: standalone)").matches || navigator.standalone;
if (/iPhone|iPad|iPod/.test(navigator.userAgent) && !standalone) $("#installHint").hidden = false;
if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js").catch(() => {});
load();
</script>
</body>
</html>
EOF_RT
sed -i "s|CONTRACT_ID: \"[A-Z0-9]*\"|CONTRACT_ID: \"$CID\"|; s|APPRAISER_URL: \"[^\"]*\"|APPRAISER_URL: \"$AURL\"|" web/index.html
cat > web/manifest.webmanifest <<'EOF_RT'
{
  "name": "Relic & Thread",
  "short_name": "Relic & Thread",
  "description": "Snap a photo, get an AI appraisal, sell antiques and handmade pieces with escrow on Stellar.",
  "start_url": "./",
  "scope": "./",
  "display": "standalone",
  "background_color": "#1e2421",
  "theme_color": "#1e2421",
  "icons": [
    { "src": "icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "icon-512.png", "sizes": "512x512", "type": "image/png" },
    { "src": "icon-maskable.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
EOF_RT
cat > web/sw.js <<'EOF_RT'
// Relic & Thread service worker: app shell offline, always fresh when online
const CACHE = "rt-v1";
const SHELL = ["./", "index.html", "manifest.webmanifest", "icon-192.png", "icon-512.png", "icon-180.png"];
self.addEventListener("install", e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL))); self.skipWaiting(); });
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return; // chain, AI and CDNs go straight to network
  e.respondWith(
    fetch(e.request).then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; })
      .catch(() => caches.match(e.request).then(r => r || caches.match("index.html")))
  );
});
EOF_RT
base64 -d > web/icon-180.png <<'EOF_RT'
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
EOF_RT
base64 -d > web/icon-192.png <<'EOF_RT'
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
EOF_RT
base64 -d > web/icon-512.png <<'EOF_RT'
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
EOF_RT
base64 -d > web/icon-maskable.png <<'EOF_RT'
iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAIAAAB7GkOtAAAmZklEQVR4nO3dd3hc5Z3o8TMzGvU2KpZkVdsqtrCNK5huYwKEjg2hJUuyAZIQ4NnkyU15bnL37u6Tsvc+m7sbSpJNSEgCZCHEgEMz1RhTXHDBuEmyrWr1Ls1o+v1DrDGyLZ2R5pz3zPy+nz/yPDgjnRczc75z2vvayirnaAAAeeyqBwAAUIMAAIBQBAAAhCIAACAUAQAAoQgAAAhFAABAKAIAAEIRAAAQigAAgFAEAACEIgAAIBQBAAChCAAACEUAAEAoAgAAQhEAABCKAACAUAQAAIQiAAAgFAEAAKEIAAAIRQAAQCgCAABCEQAAEIoAAIBQBAAAhCIAACAUAQAAoQgAAAhFAABAKAIAAEIRAAAQigAAgFAEAACEIgAAIBQBAAChCAAACEUAAEAoAgAAQhEAABCKAACAUAQAAIQiAAAgFAEAAKEIAAAIRQAAQCgCAABCEQAAEIoAAIBQBAAAhCIAACAUAQAAoQgAAAhFAABAKAIAAEIRAAAQigAAgFAEAACEIgAAIBQBAAChCAAACEUAAEAoAgAAQhEAABCKAACAUAQAAIQiAAAgFAEAAKEIAAAIRQAAQCgCAABCEQAAEIoAAIBQBAAAhEpQPYD4sbraqXoIgBSb6/yqhxAPbGWVc1SPIYax0weUIwbTRgCmg/0+YEGUIFIEIALs94GYQAl0IgC6sOsHYg4ZmBIBmEJEu37ecIAJ+FRGCwGYzJTvM95bgHJ8TqeNAJze5G8p3k+ABfGxjRQBOI1J3ka8hwCL4/OrHwGY6EzvHt46QAzhg6wHAfgU7xggzvChnhxzAX2CNwoQf870+eXG7nEEQNPY+wPxiwZMglNAp38fsOsH4gyf9FNxBHAawt8TQFzic30q6QE49UsB7xIgXp366RZ+Ikh0ANj7A9LQgJPJDQB7f0AmGnCC3AAAgHBCA8DXf0AyDgLGSQwAe38ANECTGYAJ2PsDMvHZFxcAgZEHoJO0/YO4AEzAVwBAMuF7AFkBkJZ3AJEStZeQFYAJhMcfgCZ7PyA6AAAgmaAATDiyk5x9ACebsDeQcxZIUAAAACcjAAAglJQAcP4HwCRkngWSEgAAwAQEAACEIgAAIJSIAAg5nQcgiiTsN0QEYAKuAAM4lcA9g8QAAAA0AgAAYhEAABCKAACAUAQAAIQiAAAgFAEAAKEIAAAIRQAAQCgCAABCEQAAEIoAAIBQBAAAhCIAACAUAQAAoQgAAAhFAABAKAIAAEIRAAAQigAAgFAEAACEIgAAIBQBAAChCAAACEUAAEAoAgAAQhEAABCKAACAUAQAAIQiAAAgFAEAAKEIAAAIRQAAQCgCAABCEQAAEIoAAIBQBAAAhCIAACAUAQAAoQgAAAhFAABAKAIAAEIRAAAQigAAgFAEAACEIgAAIBQBAAChCAAACEUAAEAoAgAAQhEAABCKAACAUAQAAIRKUD0AQI3UZEdmqjMzzTn+vxmpCYkJdmeCPcFhczrsCQl2p8MW1rRAMBwIhoLB8Jgv6PYGR8cC7rHgiCcwMOIbGPGNeALhsOp/E2C6CADinysjsTgvpSg3pSg3uSg3pTAnucCV7EyIwuFvIBgeHPH1DPm6+8e6Brzdg96u/rGOvrHugTHCAOsjAIhDyYmOebPTK0vSq0oyKoszcjMTDdpQgsOWm5WUm5VUU5px8p/7A6GOvrH2Xs/xHk9rj6el093a4/b5QwYNA5geAoD4UVGYtrTKtazaVV2SYbfbFI7EmWAvnZVaOiv1xJ+Ew1pn/1hz12hzp7uxfbSxY7SLowSoRgAQ22w27ayKrAsW5i2tzjHum/7M2WxaYU5yYU7yOfNzx//EPRZs7Bhp7Bg92j7a0DZ8vMdDD2AyAoBYlZ+dtHrJrDVLC/Kzk1SPZTpSkx21FVm1FVnj/+jxBo+1jzS0jRw5PrKnod89FlQ7PEhAABB7llS6rr+w+KyKLJvK0zxRlpL0aQ+++6s9x9pHVY8I8Y8AIGbYbNqq2rwbLyqZU5SmeiwGCoXCrd0e1aOACAQAseH8hXm3rCmbnZeieiCGa+8d8we4XwhmIACwurKC1K9eNffEufK419TJyR+YhADAutJSEm5dU3b5ykK193SarLnLrXoIkIIAwKIWzsl6YH21K8O6d3YapJkjAJiFAMByHA7brWvKrr+wJJ5u8tGvuZMjAJiEAMBaZrmSv3VzTWVxuuqBqOH1BbsGxlSPAlIQAFjIvNnpP/hibVaaU8nWuwe8x3s9fUO+/mGf1x/0+UNhTUty2pOcDldGYn520uzclByDHzZu7nLzPDBMQwBgFcuqXd++uSYp0WHmRo+2j+xtGPjoyMDR9hE9D9/mZiUtKMs8tzZ3WZUr0Rn95TQ4/wMzEQBYwtrlBfdcM8+0u32G3YHXdna8vbfreE9kj1z1Dnq37uveuq87Jcnx+XOLrjmvOCM1mh8i7gGFmQgA1Lv47Flfu7bSnEu+w+7Ahi0tr+3s8M5scmaPN7hhS+sr29u/fOXcNUtnRWt4HAHATAQAii2vzrn3BjP2/uGw9trOjj+/0TTiCUTrd7rHgo88V7+nof++G6uissJMcxdHADAPAYBKteWZ3/5CjcP4Mz+Do/6HNtTvaeg34pe/93HPwIj/h1+qnWED+od9w+6oxQmYEovCQ5m8rKTv3rbAiEupEzR1jn73V3sM2vuPO9A4+OCG+hnewMMzwDAZAYAaDrvtH26uSUsx/Bj0QOPgjx7d1zfkM3pD7+/veemD4zP5DTwDDJMRAKhx29ryCevoGqGudfinTxz0eE1aXOXJN5q6+qf/GBdXgGEyAgAFFs/Nvu6CYqO30j3g/dkTB8Z85i2t5fOHnt7cMu0fJwAwGQGA2RIctruumWv0bT/+QOj//tdB86+pbtnb1Tmtg4BQKNzSTQBgKgIAs11zfnFRruHrujzzdouSVRXDYe3NXZ3T+MH2PtaBgdkIAEzlykhcf3GJ0Vtp7nI/v7XN6K2cydt7u6fxU1wBhvkIAEx1+9ryZONn+/nz603BkLI51XoHvdOY0YELADAfAYB5cjITL1qcb/RWjhwf2Xm4z+itTG5vw0CkP0IAYD4CAPNcde5sh8Pwh35f3tZu9CamVN86HOmPNDEJBExHAGCS5ETHZSsKjN7K6FjgvY97jN7KlI4cH4no9V5fcCYPEADTQwBgktVLZ6UlG/7c74eH+61wL03PoNcXyWyjrAMDJQgATHLRIsPP/muatuNQrwlbmVI4rEW0siMXAKAEAYAZcjMTq0oMn/hB07T9jUMmbEWP7gGv/hczCzSUIAAww6qz8kyY8b+91zPs9hu+GX0iGglHAFCCAMAMq2pzTdhKi5WmUx6KZBaKJgIAFQgADJec6Kg25fzP4KhVvv5rmubVPQndwIjPOgcuEIUAwHDVJRnmrPY+ZKUABIJ6b+vh/A9UIQAwXLXx8/6PS3BY6P3sD+q9DZQAQBULfWAQr2rKTApARqqF1rjWv9DxNCYOAqKCAMBwlcUmBSAzzWnOhvRI1L1APEcAUIUAwFhpyQnpxi/8O66iMM2cDenh1BcA1oGBQhY6ZEZcystKMnNbWWlOi9wL9PTmlud0rEkQDoetMHcFZCIAMFZuZqKZm6sqyVA+F/Q4ry+o/05QQAlOAcFYKcmGL/9ysuXVLjM3B8Q0AgBj6b8WGhUr5+eaMOcEEB8IAIyl81potGSlO2tKM83cIhC7CACMpf+B2GhZs3SWyVsEYhQBgLHGTL8QeuGi/DSzbjwFYhoBgLHGvGYHINFp5yAA0IMAwFgjYxHMihwtV64sMmf6OSCmEQAYK6KFsaKlICf5QlNWoARiGgGAsfqHfd5IlkePlpsuKeEgAJgcAYDhOvsjWB49WopyUzgIACZHAGC4VkUrNX5hdWmCg4MA4IwIAAx3oGlIyXYLcpKvWjVbyaaBmEAAYLj9xwZVbfqmS0qzrLRIAGApBACGa+12D46omaI5Jclx69pyJZsGrI8AwAwf1imbonntsoLK4nRVWwesjADADO/v71W1aZtN+/r1lfpX6AXkIAAww75jA6MeBY8EjysvSLvugmJVWwcsiwDADMFgeNtBZQcBmqbdvLq0KDdF4QAACyIAMMkbuzoVbt2ZYP/6dfNYKwY4GQGASepahps6RxUOoLYi6+rzeCwA+BQBgHle26nyIEDTtNvXlpcVpKodA2AdBADm2bK3y2P68gAncybYH1hfzfwQwDgCAPN4vMFN29vVjqG8IO02Hg0DNE0jADDZC+8f96mYHfpk155ffPa8bLVjAKyAAMBUg6P+N3crvhJgs2kPrK/OyUxUOwxAOQIAU9VWZJUXpKkehZaZ5vzWzTU8HgzhElQPAFIsqcxef0np/LJM1QP5xPyyzFsvLXvi9SbVA5mO9JSEhXOyjN7KtoO94bDRG4FKBACGW16dc9PqUgvOyHb9hSU7D/cdbhlWPZCILZqb/e0v1Bi6if5h3wcHVD68DRMQABiopjTji5dXWOdb/wQ2m3bfuurv/HKP16fy5tRpMOFphmZF67jBTAQAhijOT7njsoqV83NUD2QKhTnJf3d5xW9eOKJ6IJExIwBKH9uGOQgAoiw9JeG2teWXLS+wx8gl1stXFm4/2Lv3yIDqgUSgfJbhF9I5ApCAu4AQNTabdumygl88sOzylYWxsvcfd+8NVWnJMfNlKMlpn+VKNnorzZ0EIP4RAETH3KL0H9+1+BvXV2akxt4avDmZiV+9eq7qUehVOivV6GlNw2GttZsAxL+Y+dYDy3Im2L+wuvS6C4pj61v/BBctzt9+sDcm7nspM/5Bio4+j/IHtmECAoAZmTc7/Zs3VpXOiocpNu+5dt7B5iFV69frV2b83zYXAITgFBCmyeGw3ba2/Md3L46Pvb+maRmpzq9fV6l6FFMrNeMWIAIgAgHAdORmJf3zVxatu7gkzmZTWFGTs2bpLNWjmIIZtwBxD6gMnAJCxJZVue5bV52RGp9vnq98fu7Hxwa7B7yqB3J6mWnOrHTDL7M3cQQgA0cAiIDNpt1xWfn376g1Yu8fDmu/eeHIsFvxKfiUJMe9N1RZdvVgEy4A+AOhzv4xo7cCKyAA0Cs50fHd2xbccFGJQTvHx19rfHVHx683qn8od+GcrM+fa9HVg014Bril2x0KMQmcCPF5FI+oy81M/P4dtRWFRp19fn1nx8Z32zRN23awd8ve7ovPzjdoQzrdcVn5nob+4z0etcM4VUSTaW8/2DviCUS6iYa2kUh/BDGKAGBqc4vSv3/HAleGUSuofHRk4LcvHj3xj4++dOSsiszcrCSDNqdHotN+/7rqH/72o6DFvgvrnwXa4w3++zN1/gC38+OMOAWEKcwvy/zfX1lo3N6/e8D7878cPnk/6x4LPvxcg/KZ6CuL02+8qETxID6rKDdF/yQQe48MsPfH5AgAJrNwTtYPv1SbkuQw6PcHg+GfP31o9JTTFPuODryievl4TdNuuqR0TpH69ctOOLsyW/+LdxyKgaeaoRYBwBktqXT94I7apESj9v6apj3+WuOZzjg//lpjm+pT8A6H7f511c4Eq3xM9K9lHwqFd9X1GzkWxAOrvLNhNbUVWd+9bX6i08B3yI5DfS+8f/xM/6/PH3poQ53yU/Cls1JvvbRM7RjGORy2syr0XgA41Dw0jcu/kIYA4DQqCtO+d9sCQ7/5Do76f/l8/eSvaWgbeXZLq3Fj0Ona84sXlKtf1KymNFP/ubgdh/oMHQziAwHARLNcyf/zS7WpyQae+dE07XcvHR12T/0V9Zm3W44cV3xXos2mffPGqmQjT4XpsaLGpf/FOw4TAEyNAOAzUpMdP/xSbXa6Uff8jNtxqO+9j3v0vDIYCj/4V/X3Mha4ku+8okLtGFbV5ul8ZUuXu7OPR3kxNQKAT9ls2v3rqotyUwzdinssGNEavG09nidebzJuPDpdtqJwaVUE38Gjq6okIz9b74MROuMKEAB8av0lpStqDF/G/ck3mvqHfRH9yEsfHP/42KBB49HvG9dXpqWoeXby/LP0fv3XNG3LR93GjQTxhADgE0sqXV9YbfjtLm09ntd3dkT6U+Gw9vCz9e6xoBFD0s+VkXj31fPM367Npq06K1fniw81D3UxlRv0IQDQNE3LSE345o2VJkyB+firjdO7s7Nn0Pv7l49O/TqDXbAo7/yFEXwZj4qq4ow83RNjbNnL13/oRQCgaZp2z7WVRl/41TRtf+PgzhncnbJ5T9e2g+qfbr3r6nkm/F2dTP/UeIFg+L39XACAXgQA2oWL81fV6j3DMBN/3NQ4w9/w641HlK/Zm5Ga8I3rzVs5Mslpv/hsvYuU7arrO3VeDeBMCIB0GanOr14114QN7WnoPzrjO/qH3f5fbWyIynhmYlm1a+3yAnO2dcGifP3Pf3H+BxEhANLdfll5uil3tjz3TltUfs/Ow31v7uqMyq+aiTuvmKP/vsyZ+NyKQp2vHPEEdtUz/w8iQABEm1OUtnaZGd9k61uH9zdG7T7Ox145pnzN3pQkx303Gr5yZEVhWmVxus4Xv7mrU/kTc4gtBEC0v79qrjmL3z63NTpf/8d5vMGHNtQpXzCgtiLr6vOMXTlS/9f/cFjbtCPi+2shHAGQ65wFufPLzJjjrHfQG/W56Q80Db3wfjSjMj23ry0vzjfqwenMNOfqJXov/35Y18ft/4gUARDKZtNuXl1qzrY27+ky4tv6n99obulyR//3RsKZYH9gXbXDbshh1DXnzdY/HffL29Svn4OYQwCEWlmTa9wK7xO8tafLiF/rD4Qe3FAXDCo+EzR3dvr6S6Kf0tRkxxUri3S+uK3Hs+/oQNTHgLhHAIS6yayv/weahoybmfJY++jTm5sN+uX6rbu4ZN5svZdqdbrynCL9M3K/sq1d+RURxCICINHiudmmLXX7tjFf/094bmtbXeuwoZuYksMe5ZUjE532q1bpvbzs8Qbf3mvsXzLiFQGQ6Ipz9d5bMkPhsOFLU4VC4Yc21Hv9im9/LM5Puf2y8mj9ts+fW5SV5tT54k3b2z1exdPkIUYRAHFys5JWVBs+5/O4utbhYbfhMze093r+9Gqj0VuZ0tWrZtfqXrN3EplpzvUX6z1B5/UFN753xnWVgckRAHEuX1FoN+aulVN9aNbChJu2t+89MmDOts7EZtPuu7FK/7QNZ3LLmjL9v2TTjg4TEot4RQBksdm0NUv13lo+cx/Wmbcy7SPP1SufBy0/O+nLV86ZyW8ozk/RP8uQ1x/a+K76hyEQuwiALAvKs1wZJk1l3D/sa+407z79viHfb19Uv2DApcsKllVPf+XIO6+Yo/+pgld3tA+O8vUf00cAZLnAxMVMzL85Z+u+bissh/uN6yszUqczv97K+Tn6lx32+UPP8/UfM0MABLHbbebM+z+urkXB3Zm/eeFIpAsOR112euLd10S8cmRaSkJEP/Xqzg7lSyMg1hEAQWrLMzN131w4c/Uqbs8f8QR++bz6BQPOOyvvwkV6l/Ea95Ur5+g/OzfqCfz17ZbIxwV8BgEQRP/phZkLhsJHZrz8y/Tsru9/LfJ156Purqvn6t+hL6tyXaJ73jdN0556q3lE9RVvxAECIMjiedmmbauzb8yn7uGsP2xqNG7+CZ3SUhLuvUHXypGpyY57rotgjcnWbverzPyMaCAAUmSlOcsLTJr+QdO0TqVTE3t9wQc31IVCiufHWVLp0jOh/zdvqMrNjODWrMdePhZU/a+G+EAApFg0L9uctV/GKZ+b/nDLsBXukf+7KyoKXMmTvOC6C4rPWRDBlfmdh/uUP/KGuEEApFhgytovJ3SpXrJR07Sn3mpu7BhVO4bkRMd96864cuSC8syIZhAKBMN/3NQYlYEBGgGQQ//SslGh/BS8pmmBYPjBDXXKl8mdX5Z57fnFp/55VrrzWzfXRLSYzHNbW9t7PdEbGqQjACI4E+xlJl4A0DStd0j9EYCmac2d7qfeUr9gwK2XlpXOSj35T5wJ9u/cMj+ip7KbO93c+onoIgAilBekJjhMvAKgaR6fVSYo3vhu26HmIbVjcCbY719X7fjv/wQ2m/YPN1VHtCBzMBR++Nn6gOrlzxBnCIAI84ozTN7imE/xiZcTwmHtoQ31Y6qDNKco7eb/XjnyrqvnRXThV9O057e2HW1X81wF4hgBEKEkP8XkLSrf4Z6ss3/sD68cUz0K7caLSiqL029aXXr5ysgW5Gnucv/FAitfIv5MZ8oqxJziPLMD4LVSADRNe/3DzpXzc2cyT+fM2e22H9xRG+lsHKFQ+BFO/sAYHAGIMDvX1ACEw5oFd1i/fL5h2K14+oRpzMX01FvNqibVQNwjAPHPbreZtgbAOJtNi+juRnMMjPj+82/q54mLyO76/mffaVU9CsQtAhD/XBmJpq0BeYIzwYpvrQ8O9L7zUbfqUejVM+j9xV/rwpY7lEL8sOKnFNGVa+7X/3FJTou+tR598WjvkOIFA/QIBMP/9tQhpvyEoSz6KUUUZaSatwbACVnpCjaqx+hY4JFn663/tfoPm441tHHqH8YiAPEvfVrLE85QjorDDp0+OjqwaXu76lFM5t19Pa9ss/QIER8IQPxLSXKYv9GczCTzN6rfn15rPN5j0Ul1DrcMP/xcvepRQAQCEP+cDgX/lc1/8iAiPn/owQ11FpxVv73X869PHlA+gR2EIADxz+RZgMaVFaRO/SKlGtpGrHaH5eCo/8d/OqD8YQXIQQDin5ILnmauPjZtz7zdctQyz1h5/aGfPXFA7UpqkIYAxD9fQMGsDK6MxMKcyVbCsoJgMPwLCywYoGlaOKz9+18Oc9sPTEYA4p+qiTnPmpOlZLsRaev2PPl6k+pRaJqm+SzQIUhDAOKfz69mz3L2vGwl243Uix8c3984qHYMNpt27w1VaclMzghTEYD45/aquai4rMpl2eeBTxYOaw8/W+/xKp6+NDcz8atXz1U7BkgTA59PzFDPoJrVGZMSHUurVE6/rF/3gPd3Lx9VPQrtosX5q2ojWygGmAkCEP+6+pUtz3vpsgJVm47U5t1d2w/1qh6Fds+1ldnp1n2IGnGGAMS/MV9waNSvZNNLKl1F5i5FMBO/3nhkUNFf1AkZqQnfuL5S7RggBwEQQdXd5TabdtW5RUo2PQ1Do/5fb1S/YMCyatdly2PmyAkxjQCIoHBJqbXLC/KyLD0v0Ml2HOrbvLtL9Si0O6+cU+Cy+lMUiAMEQITDLcOqNu1MsN+8ulTV1qfhdy8f7R5QdtVkXHKi4751VTbLLaqGeEMARDjcPKRw62uWFlQWpyscQEQ83uBDFlgwYH5Z5nUXFCseBOIdARChe8CrcBksm037+vWVFlwl+EwONA6++MFx1aPQbllTZv059RDTCIAUO5Te41hekHbTJbF0IujJ15tau91qx+BMsN+/rlrJZK4QggBI8f7HPWoHsP6S0uXVOWrHoF8wFP74mOL5ITRNqyhMu2VNmepRIG4RACkONg/1D6tcDN1m0x5YXx0TjwVUFKb95O7FV55jiRtYr7uguKY0Q/UoEJ8IgBThsLZ1X7faMaQmO753+wLLrhevaZozwX7HZeU/+9rZ82Zb5aq13W67f111UqKCdT0R9wiAIC9va1e+CGJxXso/fWWRy5JLxp+7IPf/fXPpDReVWO16dUFO8p1XVKgeBeIQARCke8D7/n7FVwK0TxqwMDfTQg2oLE7/579f9J1b5xdYdRGbz60oXFIZGzPrIYYQAFk2vtumegiapmlFuSn/+rUlCy2wYkxRbsoD66t/cvfZC8ozVY9lCvfeUJmewoIBiCYCIMux9tEPDqif81LTtKx05/+6c+FNl5Sqet61ojDtWzfX/Mf9yy5anB8Tz9y6MhLvvmae6lEgrvCFQpw/vHJsWZUr0QJLtdhs2i2Xli2rdj328rG6VpMmq7DZtIVzsq8+ryiG7kk94fyFeTsO9Sm/mI+4QQDE6Rn0PvtO6y2XWuXu8qqSjB/fvXjrvu4nX28ydBIeV0bimqWzLl1WENPzrN119dz9jYNq7+hF3CAAEj3/btsFi/JK8i00zcCFi/LPPytvV33/pu0de4/0R3EqntyspJU1OSvm5yyck2W123umIS0l4d4bqn78p/2qB4J4QAAk8gdCP3/68E/vOdtSa/ba7bYVNTkranK6B7w7DvXtPdJ/oHFozDedpXqz0p3VJRnVJRlLqlwVhWlRH6paSyqzrzinaNP2dtUDQcwjAEK1dLl/99JRay4+lZ+ddNWqoqtWFQWD4YbjI23d7rYez/EeT9fAmMcbHPOFxnxBfyCU4LAlJTqSnfbkJEd+VtIsV3KBK7kgJ3luUXp+toErEIz5gsmqH8v60uUVexv6O/rUrPODuEEA5HpzV+f8ssw1S2epHsgZORy2mtKM006EEA5rSm7d2bK3+7FXjv7jlxeWF6g8sEhy2u9fV/2TJw5oEZ4rC4XDHu90DqoQlwiAaL/e2JCV5lxWHXtPGJm/9/f6Q4++eOSt3V2apv3ir3U/u+dsZ4LKE2jVpRmPff/cSH/qcMvwD3/7kRHjQSyy0ClgmC8YCv/b04cOKV0uJibUtQ7/j1/ueeu/V4ts7nT/15vNaoc0PU0do6qHAAshANL5/KGfPnFA4aLBFhcIhp98velHj+5r7/Wc/Od/e6/tQKP6+aIj1dRJAPApAgDNPRb8p8c+tsL091ZzuGX4e7/a8+w7raFTJtELh7WHnq2PufPpjRwB4CQEAJqmaR5v8CePH9j6EY+YfmJ0LPCbF4786NGPmrvOuC5Y94D3dy8dNXNUMxQOa82dipc5g6VwERif8AdC//HXumMdo1/8XEVMzI1jkHBYe2t355NvNA2O+Kd88eY9XctrclbV5powsJnr6h+b3nMViFcEAJ+x8d22htbh+9dX52UZeCu9ZR1oHPz9y8ciOk/yn39rmF+WkZ1uodmtz6SRCwD4LE4BYaIDTUPfeWTPlr2yTgcdbR/56eMH/vH3H0d6lnzYHXjkuQaDRhVdXADABBwB4DRGxwIPbqh7e0/X3dfOK7TqGinR0tQ5+szmlm0He6c9AdHu+v5Xd3RcvrIwquOKvuYOLgDgMwgAzuijowPffnj3FecUrr+4NC6XIjnYNPTcO6276vtn/qv+uOnYorlZFl/ynlNAmCAOP9WIIn8g9MJ7x9/a1XXN+bM/f05RWlxkwB8Ivb+/5+Vt7Q1tUXv6wesPPbih/l++usiyE456vMHuAeYOwmfEw+cZRhsdCzz1ZvPzW9s+t6LwynMKZ8XsfPptPZ7Nu7ve2NU57J76Dp9I1bcOP7ul9abVpVH/zVHR1DkaxUm2ER8IAPQa8wX/9l7bC++3Lal0Xba8YGmVS+1kOPoNjvrf39/z9p6uKH7lP61n3m5ZUuWqLE43dCvTwyQQOBUBQGTCYW13ff/u+v7UZMe5C3LPOytv4Zwsa5age8C741DvtgO9B5uHzPnyGwyFH9xQ93++vsRSCy2Ma+IRMJzCVlY5R/UYDLe62nnyP26ui/7hv2RJTvuiudlLq1y1FZnFealqHyIb9QQONg99dGRgT8PAhNl7gClJ21dwBICZ8vpDOw/37Tzcp2laRqpzflnGvNnpc2enzy1Kz0p3TvnjM+QPhFq63MfaRxvahg81D7f1uDnTDehEABBNw27/jkN9Ow71jf9jWkpCcV7K7LyUQldyfnZSXlZSbmZSZpozJWk6K2q5x4L9I76+IW9nv7ejz9PRO9bW4zne6zl1pjYAehAAGGjUE6hrGa5rGZ7w5wkOW2aaMzUpISXJkZzoSHLanQl2h91mt2t2my0UDgeC4WAw7A+E3N6g2xtwjwWH3H6fP6Tk3wKIVwQACgSC4b4hX5/mUz0QQDTL3asAADAHAQAAoQgAAAhFAABAKAIAAEIRAAAQigAAgFAEAACEIgAAIBQBAAChCAAACEUAAEAoAgAAQhEAABCKAACAUAQAAIQiAAAgFAEAAKEIAAAIRQAAQCgCAABCEQAAEIoAAIBQBAAAhCIAACAUAQAAoQgAAAhFAABAKAIAAEIRAAAQigAAgFAEAACEIgAAIBQBAAChCAAACEUAAEAoAgAAQhEAABCKAACAUAQAAIQiAAAgFAEAAKEIAAAIRQAAQCgCAABCEQAAEIoAAIBQBAAAhCIAACAUAQAAoQgAAAhFAABAKAIAAEIRAAAQigAAgFASA7C62ql6CAAsR+CeQUQANtf5VQ8BQIyRsN8QEQAAwKkIAAAIRQAAQCgpAZhwOk/g1R4Ak5iwT5BwAUCTEwAAwAQEAACEEhQAzgIBOC2Z5380UQEAAJxMdAA4CAAgeT8gKwByjuwATI+ovYSsAJxKcvwBCN8DiAuAqLwDiIi0/YO4AJxK+FcAQCw++xIDcGrkeR8A0pz6qZf29V+TGQCNBgCysfcfJzQAAAC5AeAgAJCJr/8nyA2ARgMAedj7n0x0ADQaAEjC3n8C6QE4LRoAxB8+16eylVXOUT0G9c70zhD+7QCID3zAz4QjAE078/uArwxArGPvPwkC8AkaAMQf9v6T4xTQRLxjgDjAB1kPAnAak3zr590DWByfX/0IwOlNfuaHtxFgQXxsI0UAJjPlBQDeUoByfE6njQBMIaKLwLzPABPwqYwWAqAL9wIBMYdd/5QIQATIABAT2PXrRACmgxIAFsR+P1IEYEYoAaAc+/1pIwBRQwwA07DTjwoCAABCMRcQAAhFAABAKAIAAEIRAAAQigAAgFAEAACEIgAAIBQBAAChCAAACEUAAEAoAgAAQhEAABCKAACAUAQAAIQiAAAgFAEAAKEIAAAIRQAAQCgCAABCEQAAEIoAAIBQBAAAhCIAACAUAQAAoQgAAAhFAABAKAIAAEIRAAAQigAAgFAEAACEIgAAIBQBAAChCAAACEUAAEAoAgAAQhEAABCKAACAUAQAAIQiAAAgFAEAAKEIAAAIRQAAQCgCAABCEQAAEIoAAIBQBAAAhCIAACAUAQAAoQgAAAhFAABAKAIAAEIRAAAQigAAgFAEAACEIgAAIBQBAAChCAAACEUAAEAoAgAAQhEAABCKAACAUAQAAIQiAAAgFAEAAKEIAAAIRQAAQCgCAABCEQAAEIoAAIBQBAAAhCIAACAUAQAAoQgAAAhFAABAqP8Ps2Qt3YSNXGUAAAAASUVORK5CYII=
EOF_RT
for f in index.html manifest.webmanifest sw.js icon-180.png icon-192.png icon-512.png icon-maskable.png; do cp web/$f docs/$f; done
grep -q "$CID" docs/index.html && echo "site has contract $CID"
git add -A && git commit -qm "Phone app: installable PWA, Albedo wallet, test XLM button" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push -q
echo "STEP 4 DONE"
