#!/usr/bin/env bash
# Relic & Thread — one-shot setup for GitHub Codespaces
# Run:  bash setup.sh
set -e

mkdir -p "$(dirname "README.md")"
cat > README.md <<'EOF_RT'
# Relic & Thread — antiques & handmade marketplace on Stellar

Escrow marketplace: seller lists → buyer pays (funds locked in the contract) → buyer confirms receipt → seller gets paid minus platform fee. Refunds, cancellations and admin-resolved disputes included.

## Structure
- `contracts/marketplace/src/lib.rs` — Soroban smart contract
- `contracts/marketplace/src/test.rs` — unit tests (happy path, fee, refund, dispute, guards)
- `web/index.html` — single-file website (Freighter wallet + stellar-sdk from CDN)
- `deploy.sh` — build, test and deploy to testnet

## Run
```bash
# once
rustup target add wasm32v1-none
cargo install --locked stellar-cli

./deploy.sh                       # prints CONTRACT_ID
# paste CONTRACT_ID into web/index.html → CONFIG
cd web && python3 -m http.server 8080
```
Open http://localhost:8080, install the Freighter extension, switch it to **Testnet**, fund your wallet via Friendbot.

Without a CONTRACT_ID the site runs in demo mode with sample items.

## Contract API
| fn | who | what |
|---|---|---|
| `list_item(seller, title, description, image_url, category, price)` | seller | category 0 = antique, 1 = handmade; price in stroops (7 decimals) |
| `buy(buyer, id)` | buyer | moves price into escrow |
| `confirm_receipt(buyer, id)` | buyer | pays seller, fee → admin |
| `refund(seller, id)` | seller | returns escrow to buyer |
| `cancel_listing(seller, id)` / `update_price(seller, id, price)` | seller | before sale |
| `open_dispute(caller, id)` | buyer/seller | freezes the deal |
| `resolve_dispute(id, refund_buyer)` | admin | decides the dispute |
| `get_items(start, limit)`, `get_item(id)`, `item_count()` | anyone | reads |

## Ideas for the demo / next steps
- USDC instead of XLM: deploy with the USDC SAC address as `--token`, set `TOKEN_SYMBOL: "USDC"`
- Images on IPFS instead of plain URLs
- Auto-release to seller after N days if buyer doesn't respond
- Provenance certificate for antiques (hash of documents stored with the item)
EOF_RT

mkdir -p "$(dirname "Cargo.toml")"
cat > Cargo.toml <<'EOF_RT'
[workspace]
resolver = "2"
members = ["contracts/*"]

[workspace.dependencies]
soroban-sdk = "22"

[profile.release]
opt-level = "z"
overflow-checks = true
debug = 0
strip = "symbols"
debug-assertions = false
panic = "abort"
codegen-units = 1
lto = true

[profile.release-with-logs]
inherits = "release"
debug-assertions = true
EOF_RT

mkdir -p "$(dirname "deploy.sh")"
cat > deploy.sh <<'EOF_RT'
#!/usr/bin/env bash
# Build + deploy the marketplace contract to Stellar testnet.
# Needs: Rust, `stellar` CLI (https://developers.stellar.org/docs/tools/cli)
set -euo pipefail

NETWORK=testnet
ACCOUNT=${ACCOUNT:-bazaar-admin}
FEE_BPS=${FEE_BPS:-250}   # 2.5% platform fee

# 1. admin key, funded by friendbot
stellar keys generate "$ACCOUNT" --network "$NETWORK" --fund 2>/dev/null || true

# 2. tests + build
cargo test
stellar contract build
WASM=$(ls target/wasm32*/release/marketplace.wasm | head -1)

# 3. payment token: native XLM (swap for a USDC SAC address if you want stablecoins)
TOKEN=$(stellar contract id asset --asset native --network "$NETWORK")

# 4. deploy (constructor runs here)
CONTRACT_ID=$(stellar contract deploy \
  --wasm "$WASM" --source "$ACCOUNT" --network "$NETWORK" \
  -- --admin "$ACCOUNT" --token "$TOKEN" --fee_bps "$FEE_BPS")

echo
echo "CONTRACT_ID=$CONTRACT_ID"
echo "Paste it into web/index.html → CONFIG.CONTRACT_ID"
EOF_RT

mkdir -p "$(dirname "contracts/marketplace/Cargo.toml")"
cat > contracts/marketplace/Cargo.toml <<'EOF_RT'
[package]
name = "marketplace"
version = "0.1.0"
edition = "2021"
publish = false

[lib]
crate-type = ["cdylib"]
doctest = false

[dependencies]
soroban-sdk = { workspace = true }

[dev-dependencies]
soroban-sdk = { workspace = true, features = ["testutils"] }
EOF_RT

mkdir -p "$(dirname "contracts/marketplace/src/lib.rs")"
cat > contracts/marketplace/src/lib.rs <<'EOF_RT'
#![no_std]
//! Marketplace for antiques & handmade goods on Stellar (Soroban).
//!
//! Flow (escrow):
//!   seller: list_item  ->  buyer: buy (funds locked in contract)
//!   -> buyer: confirm_receipt (seller paid, platform fee to admin)
//!   alternatives: seller cancel_listing / seller refund / admin resolve_dispute

use soroban_sdk::{
    contract, contracterror, contractimpl, contracttype, symbol_short, token, Address, Env,
    String, Vec,
};

const DAY_LEDGERS: u32 = 17_280; // ~5s per ledger
const TTL_THRESHOLD: u32 = 30 * DAY_LEDGERS;
const TTL_EXTEND: u32 = 120 * DAY_LEDGERS;
const MAX_FEE_BPS: u32 = 1_000; // 10%

/// 0 = Antique, 1 = Handmade
pub const CAT_ANTIQUE: u32 = 0;
pub const CAT_HANDMADE: u32 = 1;

#[contracttype]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Status {
    Listed = 0,
    Paid = 1,
    Disputed = 2,
    Completed = 3,
    Refunded = 4,
    Cancelled = 5,
}

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Item {
    pub id: u64,
    pub seller: Address,
    pub buyer: Option<Address>,
    pub title: String,
    pub description: String,
    pub image_url: String,
    pub category: u32,
    pub price: i128,
    pub status: Status,
    pub created_at: u64,
}

#[contracttype]
#[derive(Clone)]
enum DataKey {
    Admin,
    Token,
    FeeBps,
    Count,
    Item(u64),
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    NotFound = 1,
    InvalidPrice = 2,
    InvalidCategory = 3,
    WrongStatus = 4,
    NotBuyer = 5,
    NotSeller = 6,
    SelfPurchase = 7,
    InvalidFee = 8,
    NotParty = 9,
}

#[contract]
pub struct Marketplace;

#[contractimpl]
impl Marketplace {
    /// Runs once at deploy. `token` = Stellar Asset Contract (e.g. native XLM or USDC).
    pub fn __constructor(env: Env, admin: Address, token: Address, fee_bps: u32) {
        if fee_bps > MAX_FEE_BPS {
            panic!("fee too high");
        }
        let s = env.storage().instance();
        s.set(&DataKey::Admin, &admin);
        s.set(&DataKey::Token, &token);
        s.set(&DataKey::FeeBps, &fee_bps);
        s.set(&DataKey::Count, &0u64);
    }

    // ---------------- seller ----------------

    pub fn list_item(
        env: Env,
        seller: Address,
        title: String,
        description: String,
        image_url: String,
        category: u32,
        price: i128,
    ) -> Result<u64, Error> {
        seller.require_auth();
        if price <= 0 {
            return Err(Error::InvalidPrice);
        }
        if category != CAT_ANTIQUE && category != CAT_HANDMADE {
            return Err(Error::InvalidCategory);
        }
        let id: u64 = env.storage().instance().get(&DataKey::Count).unwrap_or(0) + 1;
        let item = Item {
            id,
            seller: seller.clone(),
            buyer: None,
            title,
            description,
            image_url,
            category,
            price,
            status: Status::Listed,
            created_at: env.ledger().timestamp(),
        };
        save(&env, &item);
        env.storage().instance().set(&DataKey::Count, &id);
        bump_instance(&env);
        env.events()
            .publish((symbol_short!("listed"), seller), (id, price));
        Ok(id)
    }

    pub fn update_price(env: Env, seller: Address, id: u64, price: i128) -> Result<(), Error> {
        seller.require_auth();
        let mut item = load(&env, id)?;
        if item.seller != seller {
            return Err(Error::NotSeller);
        }
        if item.status != Status::Listed {
            return Err(Error::WrongStatus);
        }
        if price <= 0 {
            return Err(Error::InvalidPrice);
        }
        item.price = price;
        save(&env, &item);
        Ok(())
    }

    pub fn cancel_listing(env: Env, seller: Address, id: u64) -> Result<(), Error> {
        seller.require_auth();
        let mut item = load(&env, id)?;
        if item.seller != seller {
            return Err(Error::NotSeller);
        }
        if item.status != Status::Listed {
            return Err(Error::WrongStatus);
        }
        item.status = Status::Cancelled;
        save(&env, &item);
        env.events().publish((symbol_short!("cancel"), seller), id);
        Ok(())
    }

    /// Seller voluntarily returns the money (e.g. item can't be shipped).
    pub fn refund(env: Env, seller: Address, id: u64) -> Result<(), Error> {
        seller.require_auth();
        let mut item = load(&env, id)?;
        if item.seller != seller {
            return Err(Error::NotSeller);
        }
        if item.status != Status::Paid && item.status != Status::Disputed {
            return Err(Error::WrongStatus);
        }
        let buyer = item.buyer.clone().unwrap();
        token_client(&env).transfer(&env.current_contract_address(), &buyer, &item.price);
        item.status = Status::Refunded;
        save(&env, &item);
        env.events().publish((symbol_short!("refund"), buyer), id);
        Ok(())
    }

    // ---------------- buyer ----------------

    /// Locks the price in escrow inside this contract.
    pub fn buy(env: Env, buyer: Address, id: u64) -> Result<(), Error> {
        buyer.require_auth();
        let mut item = load(&env, id)?;
        if item.status != Status::Listed {
            return Err(Error::WrongStatus);
        }
        if item.seller == buyer {
            return Err(Error::SelfPurchase);
        }
        token_client(&env).transfer(&buyer, &env.current_contract_address(), &item.price);
        item.buyer = Some(buyer.clone());
        item.status = Status::Paid;
        save(&env, &item);
        env.events()
            .publish((symbol_short!("bought"), buyer), (id, item.price));
        Ok(())
    }

    /// Buyer got the item → seller receives price minus platform fee.
    pub fn confirm_receipt(env: Env, buyer: Address, id: u64) -> Result<(), Error> {
        buyer.require_auth();
        let mut item = load(&env, id)?;
        if item.buyer != Some(buyer.clone()) {
            return Err(Error::NotBuyer);
        }
        if item.status != Status::Paid {
            return Err(Error::WrongStatus);
        }
        payout_seller(&env, &item);
        item.status = Status::Completed;
        save(&env, &item);
        env.events().publish((symbol_short!("done"), buyer), id);
        Ok(())
    }

    /// Buyer or seller freezes the deal; only admin can resolve it afterwards.
    pub fn open_dispute(env: Env, caller: Address, id: u64) -> Result<(), Error> {
        caller.require_auth();
        let mut item = load(&env, id)?;
        if item.status != Status::Paid {
            return Err(Error::WrongStatus);
        }
        if item.buyer != Some(caller.clone()) && item.seller != caller {
            return Err(Error::NotParty);
        }
        item.status = Status::Disputed;
        save(&env, &item);
        env.events().publish((symbol_short!("dispute"), caller), id);
        Ok(())
    }

    // ---------------- admin ----------------

    pub fn resolve_dispute(env: Env, id: u64, refund_buyer: bool) -> Result<(), Error> {
        read_admin(&env).require_auth();
        let mut item = load(&env, id)?;
        if item.status != Status::Disputed {
            return Err(Error::WrongStatus);
        }
        if refund_buyer {
            let buyer = item.buyer.clone().unwrap();
            token_client(&env).transfer(&env.current_contract_address(), &buyer, &item.price);
            item.status = Status::Refunded;
        } else {
            payout_seller(&env, &item);
            item.status = Status::Completed;
        }
        save(&env, &item);
        env.events().publish((symbol_short!("resolved"),), (id, refund_buyer));
        Ok(())
    }

    pub fn set_fee(env: Env, fee_bps: u32) -> Result<(), Error> {
        read_admin(&env).require_auth();
        if fee_bps > MAX_FEE_BPS {
            return Err(Error::InvalidFee);
        }
        env.storage().instance().set(&DataKey::FeeBps, &fee_bps);
        Ok(())
    }

    pub fn set_admin(env: Env, new_admin: Address) {
        read_admin(&env).require_auth();
        env.storage().instance().set(&DataKey::Admin, &new_admin);
    }

    // ---------------- views ----------------

    pub fn get_item(env: Env, id: u64) -> Result<Item, Error> {
        load(&env, id)
    }

    /// Newest first. `start` = 0 means "from the newest".
    pub fn get_items(env: Env, start: u64, limit: u32) -> Vec<Item> {
        let count: u64 = env.storage().instance().get(&DataKey::Count).unwrap_or(0);
        let mut out = Vec::new(&env);
        let mut id = if start == 0 || start > count { count } else { start };
        let limit = if limit > 50 { 50 } else { limit };
        while id > 0 && out.len() < limit {
            if let Some(item) = env.storage().persistent().get::<_, Item>(&DataKey::Item(id)) {
                out.push_back(item);
            }
            id -= 1;
        }
        out
    }

    pub fn item_count(env: Env) -> u64 {
        env.storage().instance().get(&DataKey::Count).unwrap_or(0)
    }

    pub fn get_token(env: Env) -> Address {
        env.storage().instance().get(&DataKey::Token).unwrap()
    }

    pub fn fee_bps(env: Env) -> u32 {
        env.storage().instance().get(&DataKey::FeeBps).unwrap_or(0)
    }

    pub fn get_admin(env: Env) -> Address {
        read_admin(&env)
    }
}

// ---------------- helpers ----------------

fn read_admin(env: &Env) -> Address {
    env.storage().instance().get(&DataKey::Admin).unwrap()
}

fn token_client(env: &Env) -> token::Client<'_> {
    let addr: Address = env.storage().instance().get(&DataKey::Token).unwrap();
    token::Client::new(env, &addr)
}

fn load(env: &Env, id: u64) -> Result<Item, Error> {
    let key = DataKey::Item(id);
    let item: Item = env
        .storage()
        .persistent()
        .get(&key)
        .ok_or(Error::NotFound)?;
    env.storage()
        .persistent()
        .extend_ttl(&key, TTL_THRESHOLD, TTL_EXTEND);
    Ok(item)
}

fn save(env: &Env, item: &Item) {
    let key = DataKey::Item(item.id);
    env.storage().persistent().set(&key, item);
    env.storage()
        .persistent()
        .extend_ttl(&key, TTL_THRESHOLD, TTL_EXTEND);
}

fn bump_instance(env: &Env) {
    env.storage()
        .instance()
        .extend_ttl(TTL_THRESHOLD, TTL_EXTEND);
}

fn payout_seller(env: &Env, item: &Item) {
    let fee_bps: u32 = env.storage().instance().get(&DataKey::FeeBps).unwrap_or(0);
    let fee = item.price * fee_bps as i128 / 10_000;
    let to_seller = item.price - fee;
    let tk = token_client(env);
    let me = env.current_contract_address();
    tk.transfer(&me, &item.seller, &to_seller);
    if fee > 0 {
        tk.transfer(&me, &read_admin(env), &fee);
    }
}

#[cfg(test)]
mod test;
EOF_RT

mkdir -p "$(dirname "contracts/marketplace/src/test.rs")"
cat > contracts/marketplace/src/test.rs <<'EOF_RT'
#![cfg(test)]
use super::*;
use soroban_sdk::{testutils::Address as _, token::StellarAssetClient, Address, Env, String};

struct Setup<'a> {
    env: Env,
    client: MarketplaceClient<'a>,
    token: token::Client<'a>,
    admin: Address,
    seller: Address,
    buyer: Address,
}

fn setup<'a>() -> Setup<'a> {
    let env = Env::default();
    env.mock_all_auths();

    let admin = Address::generate(&env);
    let seller = Address::generate(&env);
    let buyer = Address::generate(&env);

    let sac = env.register_stellar_asset_contract_v2(admin.clone());
    let token_addr = sac.address();
    StellarAssetClient::new(&env, &token_addr).mint(&buyer, &1_000_0000000);

    // 2.5% platform fee
    let id = env.register(Marketplace, (admin.clone(), token_addr.clone(), 250u32));
    let client = MarketplaceClient::new(&env, &id);
    let token = token::Client::new(&env, &token_addr);

    Setup { env, client, token, admin, seller, buyer }
}

fn list(s: &Setup, price: i128) -> u64 {
    s.client.list_item(
        &s.seller,
        &String::from_str(&s.env, "Art Deco vase 1920s"),
        &String::from_str(&s.env, "Amber glass, signed"),
        &String::from_str(&s.env, "https://example.com/vase.jpg"),
        &CAT_ANTIQUE,
        &price,
    )
}

#[test]
fn happy_path_with_fee() {
    let s = setup();
    let id = list(&s, 100_0000000);
    assert_eq!(id, 1);

    s.client.buy(&s.buyer, &id);
    assert_eq!(s.token.balance(&s.client.address), 100_0000000);
    assert_eq!(s.client.get_item(&id).status, Status::Paid);

    s.client.confirm_receipt(&s.buyer, &id);
    assert_eq!(s.token.balance(&s.seller), 97_5000000);
    assert_eq!(s.token.balance(&s.admin), 2_5000000);
    assert_eq!(s.token.balance(&s.client.address), 0);
    assert_eq!(s.client.get_item(&id).status, Status::Completed);
}

#[test]
fn seller_refund() {
    let s = setup();
    let id = list(&s, 50_0000000);
    s.client.buy(&s.buyer, &id);
    s.client.refund(&s.seller, &id);
    assert_eq!(s.token.balance(&s.buyer), 1_000_0000000);
    assert_eq!(s.client.get_item(&id).status, Status::Refunded);
}

#[test]
fn dispute_resolved_for_buyer() {
    let s = setup();
    let id = list(&s, 50_0000000);
    s.client.buy(&s.buyer, &id);
    s.client.open_dispute(&s.buyer, &id);
    s.client.resolve_dispute(&id, &true);
    assert_eq!(s.token.balance(&s.buyer), 1_000_0000000);
}

#[test]
fn cannot_buy_twice_or_own_item() {
    let s = setup();
    let id = list(&s, 10_0000000);
    assert_eq!(s.client.try_buy(&s.seller, &id), Err(Ok(Error::SelfPurchase)));
    s.client.buy(&s.buyer, &id);
    let other = Address::generate(&s.env);
    assert_eq!(s.client.try_buy(&other, &id), Err(Ok(Error::WrongStatus)));
}

#[test]
fn only_buyer_confirms() {
    let s = setup();
    let id = list(&s, 10_0000000);
    s.client.buy(&s.buyer, &id);
    assert_eq!(
        s.client.try_confirm_receipt(&s.seller, &id),
        Err(Ok(Error::NotBuyer))
    );
}

#[test]
fn listing_newest_first() {
    let s = setup();
    list(&s, 1);
    list(&s, 2);
    list(&s, 3);
    let items = s.client.get_items(&0, &2);
    assert_eq!(items.len(), 2);
    assert_eq!(items.get(0).unwrap().id, 3);
    assert_eq!(items.get(1).unwrap().id, 2);
}

#[test]
fn rejects_bad_input() {
    let s = setup();
    let t = String::from_str(&s.env, "x");
    assert_eq!(
        s.client.try_list_item(&s.seller, &t, &t, &t, &CAT_HANDMADE, &0),
        Err(Ok(Error::InvalidPrice))
    );
    assert_eq!(
        s.client.try_list_item(&s.seller, &t, &t, &t, &7, &5),
        Err(Ok(Error::InvalidCategory))
    );
}
EOF_RT

mkdir -p "$(dirname "web/index.html")"
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
  CONTRACT_ID: "",                    // C... after deploy
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
    <div class="img" style="background-image:url('${esc(it.image_url)}')"></div>
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

chmod +x deploy.sh
printf 'target/\n.stellar/\n' > .gitignore

echo "== Installing Rust targets =="
rustup target add wasm32v1-none wasm32-unknown-unknown || true

echo "== Installing Stellar CLI =="
if ! command -v stellar >/dev/null; then
  curl -fsSL https://github.com/stellar/stellar-cli/raw/main/install.sh | sh || cargo install --locked stellar-cli
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
stellar --version

echo "== Running contract tests =="
cargo test

echo
echo "ALL GOOD. Next: ./deploy.sh"
