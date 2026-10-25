#!/usr/bin/env bash
# Step 2: live website + real testnet trade + push to GitHub
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd /workspaces/sansara
ID=CD6GNUPVRAAF4U3EWOE5RDNVWX6JM4QORVQUAADTNHWQGA4LER6IAWD3
NET="--network testnet"

# tidy: the uploaded copy becomes the real setup.sh
[ -f "setup 2.sh" ] && mv -f "setup 2.sh" setup.sh

echo "== Updating website =="
mkdir -p web docs
cat > web/index.html <<'EOF_RT'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
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
header{position:sticky;top:0;z-index:5;background:var(--paper);border-bottom:1px solid var(--line)}
.bar{max-width:1100px;margin:auto;padding:14px 16px;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.logo{font:600 26px/1 "Cormorant Garamond",serif;letter-spacing:.5px;margin-right:auto}
.logo i{color:var(--accent);font-weight:500}
nav{display:flex;gap:4px}
nav button,.chip{background:none;border:1px solid transparent;color:var(--muted);padding:7px 12px;border-radius:999px;font:500 14px Inter;cursor:pointer}
nav button.on{color:var(--ink);border-color:var(--line);background:var(--card)}
.btn{background:var(--accent);color:var(--accent-ink);border:0;border-radius:10px;padding:10px 16px;font:600 14px Inter;cursor:pointer}
.btn.ghost{background:none;color:var(--ink);border:1px solid var(--line)}
.btn:disabled{opacity:.5;cursor:default}
main{max-width:1100px;margin:auto;padding:20px 16px 60px}
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
    <div id="demoBanner" class="banner" hidden>Demo mode: add your CONTRACT_ID in the config to go live on testnet.</div>
    <div class="filters">
      <button class="chip on" data-cat="all">All</button>
      <button class="chip" data-cat="0">Antique</button>
      <button class="chip" data-cat="1">Handmade</button>
    </div>
    <div class="grid" id="grid"></div>
  </section>

  <section id="sell" hidden>
    <div class="hero"><h1>List a piece</h1><p>It goes on-chain under your wallet. You get paid when the buyer confirms receipt.</p></div>
    <form id="sellForm">
      <label>Title<input name="title" required maxlength="80"></label>
      <label>Description<textarea name="description" required maxlength="600"></textarea></label>
      <label>Image URL<input name="image" type="url" placeholder="https://…" required></label>
      <div class="two">
        <label>Category<select name="category"><option value="0">Antique</option><option value="1">Handmade</option></select></label>
        <label>Price (<span class="sym">XLM</span>)<input name="price" type="number" min="0.0000001" step="0.0000001" required></label>
      </div>
      <button class="btn" type="submit">List on Stellar</button>
      <div class="note">Platform fee is taken only from completed sales.</div>
    </form>
  </section>

  <section id="mine" hidden>
    <div class="hero"><h1>My deals</h1><p>Your listings and purchases.</p></div>
    <div class="grid" id="mineGrid"></div>
  </section>
</main>
<div id="toast"></div>

<script>
// ================= CONFIG =================
const CONFIG = {
  CONTRACT_ID: "CD6GNUPVRAAF4U3EWOE5RDNVWX6JM4QORVQUAADTNHWQGA4LER6IAWD3",
  NETWORK: "TESTNET",                 // or "PUBLIC"
  RPC_URL: "https://soroban-testnet.stellar.org",
  TOKEN_SYMBOL: "XLM",
  DECIMALS: 7,
};
// ==========================================

const S = window.StellarSdk;
const F = window.freighterApi;
const PASSPHRASE = S.Networks[CONFIG.NETWORK];
const server = new S.rpc.Server(CONFIG.RPC_URL);
const STATUS = ["Listed","Paid","Disputed","Completed","Refunded","Cancelled"];
const CAT = ["Antique","Handmade"];
const ERR = {1:"Item not found",2:"Invalid price",3:"Invalid category",4:"Not possible in this state",5:"Only the buyer can do this",6:"Only the seller can do this",7:"You can't buy your own item",8:"Invalid fee",9:"Not part of this deal"};
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
  const acc = await server.getAccount(me);
  let tx = new S.TransactionBuilder(acc, {fee:S.BASE_FEE, networkPassphrase:PASSPHRASE})
    .addOperation(new S.Contract(CONFIG.CONTRACT_ID).call(method, ...args)).setTimeout(60).build();
  tx = await server.prepareTransaction(tx);
  const signed = await F.signTransaction(tx.toXDR(), {networkPassphrase:PASSPHRASE, address:me});
  if (signed.error) throw new Error(signed.error.message || signed.error);
  const xdr = signed.signedTxXdr || signed;
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

async function connect(){
  if (!F) { toast("Install the Freighter wallet extension"); throw new Error("no wallet"); }
  const c = await F.isConnected();
  if (!(c?.isConnected ?? c)) { toast("Install the Freighter wallet extension"); throw new Error("no wallet"); }
  const r = await F.requestAccess();
  if (r.error) { toast(r.error.message || "Wallet access denied"); throw new Error("denied"); }
  me = r.address || r;
  $("#connect").textContent = short(me);
  render();
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

function card(it, mode){
  const st = STATUS[Number(it.status)];
  const isSeller = me && it.seller === me, isBuyer = me && it.buyer === me;
  let act = "";
  if (mode === "shop" && st === "Listed" && !isSeller) act = `<button class="btn" data-a="buy" data-id="${it.id}">Buy</button>`;
  if (mode === "mine"){
    if (isSeller && st==="Listed")  act += `<button class="btn ghost" data-a="cancel_listing" data-id="${it.id}">Cancel</button>`;
    if (isSeller && (st==="Paid"||st==="Disputed")) act += `<button class="btn ghost" data-a="refund" data-id="${it.id}">Refund</button>`;
    if (isBuyer && st==="Paid") act += `<button class="btn" data-a="confirm_receipt" data-id="${it.id}">Got it ✓</button>`;
    if ((isBuyer||isSeller) && st==="Paid") act += `<button class="btn ghost" data-a="open_dispute" data-id="${it.id}">Dispute</button>`;
  }
  const who = mode==="mine" ? `<span class="status">${isSeller?"selling":"bought"}</span>` : "";
  return `<article class="card">
    <div class="img" style="background-image:url('${esc(it.image_url || placeholder(it))}')"></div>
    <div class="body">
      <span class="tag">${CAT[Number(it.category)]||""} · #${it.id}</span>
      <h3>${esc(it.title)}</h3>
      <p>${esc(it.description)}</p>
      <div class="row"><span class="price">${fromUnits(it.price)} ${CONFIG.TOKEN_SYMBOL}</span><span class="status ${st}">${st==="Listed"?"":st}</span></div>
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
$("#connect").onclick = () => connect().catch(()=>{});

document.body.addEventListener("click", async e => {
  const b = e.target.closest("[data-a]"); if (!b) return;
  if (DEMO) return toast("Demo mode — deploy the contract to trade for real");
  const a = b.dataset.a, id = b.dataset.id;
  b.disabled = true; toast("Confirm in Freighter…", 8000);
  try {
    if (!me) await connect();
    await write(a, A.addr(me), A.u64(id));
    toast({buy:"Paid! Funds are held in escrow.",confirm_receipt:"Done — seller has been paid.",refund:"Refunded.",cancel_listing:"Listing cancelled.",open_dispute:"Dispute opened."}[a]);
    await load();
  } catch(err){ toast(niceError(err)); b.disabled = false; }
});

$("#sellForm").onsubmit = async e => {
  e.preventDefault();
  if (DEMO) return toast("Demo mode — deploy the contract to list for real");
  const f = new FormData(e.target), btn = e.target.querySelector("button");
  btn.disabled = true; toast("Confirm in Freighter…", 8000);
  try {
    if (!me) await connect();
    const id = await write("list_item", A.addr(me), A.str(f.get("title")), A.str(f.get("description")),
      A.str(f.get("image")), A.u32(f.get("category")), A.i128(toUnits(f.get("price"))));
    toast(`Listed as #${id}`); e.target.reset(); await load();
    document.querySelector('nav [data-tab="shop"]').click();
  } catch(err){ toast(niceError(err)); }
  btn.disabled = false;
};

load();
</script>
</body>
</html>
EOF_RT
cp web/index.html docs/index.html

echo "== Creating seller and buyer wallets =="
stellar keys generate seller $NET --fund 2>/dev/null || true
stellar keys generate buyer  $NET --fund 2>/dev/null || true

inv() { stellar contract invoke --id $ID $NET --source "$1" -- "${@:2}"; }

echo "== Listing 3 pieces =="
V=$(inv seller list_item --seller seller --title "Art Deco glass vase, 1920s" --description "Hand-blown amber glass, signed on the base, no chips or cracks." --image_url "" --category 0 --price 4200000000 | tr -d '"')
inv seller list_item --seller seller --title "Moonstone wire-wrap pendant" --description "Silver wire, wrapped by hand. One of one." --image_url "" --category 1 --price 650000000
inv seller list_item --seller seller --title "Art nouveau oak mirror" --description "Carved oak frame, Paris c. 1905, original silvering." --image_url "" --category 0 --price 2900000000

echo "== Buying the vase (escrow) =="
inv buyer buy --buyer buyer --id $V
echo "== Buyer confirms receipt (seller paid) =="
inv buyer confirm_receipt --buyer buyer --id $V

echo "== Saving to GitHub =="
git add -A
git commit -m "Relic & Thread: Soroban escrow marketplace, live on testnet" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DJSrn6THa5gvXGLtCBCP6T" >/dev/null
git push

echo "== Turning on the public website =="
gh api -X POST repos/karmainaria/sansara/pages -f "source[branch]=main" -f "source[path]=/docs" >/dev/null 2>&1 \
  && echo "Website will be live in ~1 min: https://karmainaria.github.io/sansara/" \
  || echo "Turn on Pages manually: Settings > Pages > Branch main, folder /docs"

echo
echo "CONTRACT: https://stellar.expert/explorer/testnet/contract/$ID"
echo "ALL DONE"
