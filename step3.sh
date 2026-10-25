#!/usr/bin/env bash
# Step 3: AI appraiser — new contract, server, website
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd /workspaces/sansara
set -e

mkdir -p "$(dirname "contracts/marketplace/src/lib.rs")"
cat > contracts/marketplace/src/lib.rs <<'EOF_RT'
#![no_std]
//! Relic & Thread — marketplace for antiques & handmade goods on Stellar (Soroban).
//!
//! Flow:
//!   seller: submit_item(photos)            -> status Pending (no price yet)
//!   AI appraiser: appraise(id, title, ...)  -> status Listed, price set by the AI
//!   buyer: buy (funds locked in escrow) -> buyer: confirm_receipt (seller paid, fee to admin)
//!   alternatives: seller cancel_listing / seller refund / admin resolve_dispute
//!
//! Only the appraiser address (an AI agent with its own Stellar key) can set a price.
//! Sellers cannot change it; if they disagree they can withdraw the item.

use soroban_sdk::{
    contract, contracterror, contractimpl, contracttype, symbol_short, token, Address, Env,
    String, Vec,
};

const DAY_LEDGERS: u32 = 17_280; // ~5s per ledger
const TTL_THRESHOLD: u32 = DAY_LEDGERS;
const TTL_EXTEND: u32 = 7 * DAY_LEDGERS;
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
    Pending = 6,
}

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Item {
    pub id: u64,
    pub seller: Address,
    pub buyer: Option<Address>,
    pub title: String,
    pub description: String,
    /// One or more photo URLs, separated by spaces
    pub image_url: String,
    pub category: u32,
    pub price: i128,
    pub status: Status,
    pub created_at: u64,
    /// AI appraisal as compact JSON (era, origin, maker, story, value in EUR, confidence...)
    pub report: String,
}

#[contracttype]
#[derive(Clone)]
enum DataKey {
    Admin,
    Token,
    FeeBps,
    Count,
    Appraiser,
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
    NoPhotos = 10,
}

#[contract]
pub struct Marketplace;

#[contractimpl]
impl Marketplace {
    /// `token` = Stellar Asset Contract (native XLM or USDC). `appraiser` = AI agent's address.
    pub fn __constructor(env: Env, admin: Address, token: Address, fee_bps: u32, appraiser: Address) {
        if fee_bps > MAX_FEE_BPS {
            panic!("fee too high");
        }
        let s = env.storage().instance();
        s.set(&DataKey::Admin, &admin);
        s.set(&DataKey::Token, &token);
        s.set(&DataKey::FeeBps, &fee_bps);
        s.set(&DataKey::Appraiser, &appraiser);
        s.set(&DataKey::Count, &0u64);
    }

    // ---------------- seller ----------------

    /// Seller only provides photos. Title, story and price come from the AI appraiser.
    pub fn submit_item(env: Env, seller: Address, image_url: String) -> Result<u64, Error> {
        seller.require_auth();
        if image_url.len() == 0 {
            return Err(Error::NoPhotos);
        }
        let id: u64 = env.storage().instance().get(&DataKey::Count).unwrap_or(0) + 1;
        let empty = String::from_str(&env, "");
        let item = Item {
            id,
            seller: seller.clone(),
            buyer: None,
            title: empty.clone(),
            description: empty.clone(),
            image_url,
            category: CAT_ANTIQUE,
            price: 0,
            status: Status::Pending,
            created_at: env.ledger().timestamp(),
            report: empty,
        };
        save(&env, &item);
        env.storage().instance().set(&DataKey::Count, &id);
        bump_instance(&env);
        env.events().publish((symbol_short!("submit"), seller), id);
        Ok(id)
    }

    /// Withdraw an item that is not sold yet (pending or listed).
    pub fn cancel_listing(env: Env, seller: Address, id: u64) -> Result<(), Error> {
        seller.require_auth();
        let mut item = load(&env, id)?;
        if item.seller != seller {
            return Err(Error::NotSeller);
        }
        if item.status != Status::Listed && item.status != Status::Pending {
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

    // ---------------- AI appraiser ----------------

    /// Called by the AI agent after examining the photos. Sets identity, story and price.
    pub fn appraise(
        env: Env,
        id: u64,
        title: String,
        description: String,
        category: u32,
        price: i128,
        report: String,
    ) -> Result<(), Error> {
        read_appraiser(&env).require_auth();
        let mut item = load(&env, id)?;
        if item.status != Status::Pending {
            return Err(Error::WrongStatus);
        }
        if price <= 0 {
            return Err(Error::InvalidPrice);
        }
        if category != CAT_ANTIQUE && category != CAT_HANDMADE {
            return Err(Error::InvalidCategory);
        }
        item.title = title;
        item.description = description;
        item.category = category;
        item.price = price;
        item.report = report;
        item.status = Status::Listed;
        save(&env, &item);
        env.events()
            .publish((symbol_short!("appraised"),), (id, price));
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

    pub fn set_appraiser(env: Env, appraiser: Address) {
        read_admin(&env).require_auth();
        env.storage().instance().set(&DataKey::Appraiser, &appraiser);
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

    pub fn get_appraiser(env: Env) -> Address {
        read_appraiser(&env)
    }
}

// ---------------- helpers ----------------

fn read_admin(env: &Env) -> Address {
    env.storage().instance().get(&DataKey::Admin).unwrap()
}

fn read_appraiser(env: &Env) -> Address {
    env.storage().instance().get(&DataKey::Appraiser).unwrap()
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
    let appraiser = Address::generate(&env);
    let seller = Address::generate(&env);
    let buyer = Address::generate(&env);

    let sac = env.register_stellar_asset_contract_v2(admin.clone());
    let token_addr = sac.address();
    StellarAssetClient::new(&env, &token_addr).mint(&buyer, &1_000_0000000);

    // 2.5% platform fee
    let id = env.register(
        Marketplace,
        (admin.clone(), token_addr.clone(), 250u32, appraiser.clone()),
    );
    let client = MarketplaceClient::new(&env, &id);
    let token = token::Client::new(&env, &token_addr);

    Setup { env, client, token, admin, seller, buyer }
}

fn s(env: &Env, v: &str) -> String {
    String::from_str(env, v)
}

/// Seller submits photos, AI appraiser prices the piece.
fn list(st: &Setup, price: i128) -> u64 {
    let id = st
        .client
        .submit_item(&st.seller, &s(&st.env, "https://example.com/vase-1.jpg https://example.com/vase-2.jpg"));
    st.client.appraise(
        &id,
        &s(&st.env, "Art Deco amber glass vase"),
        &s(&st.env, "Hand-blown, Bohemia, 1920s"),
        &CAT_ANTIQUE,
        &price,
        &s(&st.env, "{\"era\":\"1920s\",\"value_eur\":120}"),
    );
    id
}

#[test]
fn submit_then_ai_appraisal() {
    let st = setup();
    let id = st.client.submit_item(&st.seller, &s(&st.env, "https://example.com/a.jpg"));
    let item = st.client.get_item(&id);
    assert_eq!(item.status, Status::Pending);
    assert_eq!(item.price, 0);

    // not buyable before the AI sets a price
    assert_eq!(st.client.try_buy(&st.buyer, &id), Err(Ok(Error::WrongStatus)));

    st.client.appraise(
        &id,
        &s(&st.env, "Moonstone pendant"),
        &s(&st.env, "Silver wire-wrap"),
        &CAT_HANDMADE,
        &65_0000000,
        &s(&st.env, "{}"),
    );
    let item = st.client.get_item(&id);
    assert_eq!(item.status, Status::Listed);
    assert_eq!(item.price, 65_0000000);
    assert_eq!(item.category, CAT_HANDMADE);

    // cannot be appraised twice
    assert_eq!(
        st.client.try_appraise(&id, &s(&st.env, "x"), &s(&st.env, "x"), &CAT_ANTIQUE, &1, &s(&st.env, "")),
        Err(Ok(Error::WrongStatus))
    );
}

#[test]
fn rejects_empty_photos_and_bad_appraisal() {
    let st = setup();
    assert_eq!(
        st.client.try_submit_item(&st.seller, &s(&st.env, "")),
        Err(Ok(Error::NoPhotos))
    );
    let id = st.client.submit_item(&st.seller, &s(&st.env, "https://x/y.jpg"));
    let t = s(&st.env, "t");
    assert_eq!(
        st.client.try_appraise(&id, &t, &t, &CAT_ANTIQUE, &0, &t),
        Err(Ok(Error::InvalidPrice))
    );
    assert_eq!(
        st.client.try_appraise(&id, &t, &t, &7, &5, &t),
        Err(Ok(Error::InvalidCategory))
    );
}

#[test]
fn happy_path_with_fee() {
    let st = setup();
    let id = list(&st, 100_0000000);
    assert_eq!(id, 1);

    st.client.buy(&st.buyer, &id);
    assert_eq!(st.token.balance(&st.client.address), 100_0000000);
    assert_eq!(st.client.get_item(&id).status, Status::Paid);

    st.client.confirm_receipt(&st.buyer, &id);
    assert_eq!(st.token.balance(&st.seller), 97_5000000);
    assert_eq!(st.token.balance(&st.admin), 2_5000000);
    assert_eq!(st.token.balance(&st.client.address), 0);
    assert_eq!(st.client.get_item(&id).status, Status::Completed);
}

#[test]
fn seller_can_withdraw_pending_or_listed() {
    let st = setup();
    let pending = st.client.submit_item(&st.seller, &s(&st.env, "https://x/y.jpg"));
    st.client.cancel_listing(&st.seller, &pending);
    assert_eq!(st.client.get_item(&pending).status, Status::Cancelled);

    let listed = list(&st, 10_0000000);
    st.client.cancel_listing(&st.seller, &listed);
    assert_eq!(st.client.get_item(&listed).status, Status::Cancelled);
}

#[test]
fn seller_refund() {
    let st = setup();
    let id = list(&st, 50_0000000);
    st.client.buy(&st.buyer, &id);
    st.client.refund(&st.seller, &id);
    assert_eq!(st.token.balance(&st.buyer), 1_000_0000000);
    assert_eq!(st.client.get_item(&id).status, Status::Refunded);
}

#[test]
fn dispute_resolved_for_buyer() {
    let st = setup();
    let id = list(&st, 50_0000000);
    st.client.buy(&st.buyer, &id);
    st.client.open_dispute(&st.buyer, &id);
    st.client.resolve_dispute(&id, &true);
    assert_eq!(st.token.balance(&st.buyer), 1_000_0000000);
}

#[test]
fn cannot_buy_twice_or_own_item() {
    let st = setup();
    let id = list(&st, 10_0000000);
    assert_eq!(st.client.try_buy(&st.seller, &id), Err(Ok(Error::SelfPurchase)));
    st.client.buy(&st.buyer, &id);
    let other = Address::generate(&st.env);
    assert_eq!(st.client.try_buy(&other, &id), Err(Ok(Error::WrongStatus)));
}

#[test]
fn only_buyer_confirms() {
    let st = setup();
    let id = list(&st, 10_0000000);
    st.client.buy(&st.buyer, &id);
    assert_eq!(
        st.client.try_confirm_receipt(&st.seller, &id),
        Err(Ok(Error::NotBuyer))
    );
}

#[test]
fn listing_newest_first() {
    let st = setup();
    list(&st, 1);
    list(&st, 2);
    list(&st, 3);
    let items = st.client.get_items(&0, &2);
    assert_eq!(items.len(), 2);
    assert_eq!(items.get(0).unwrap().id, 3);
    assert_eq!(items.get(1).unwrap().id, 2);
}
EOF_RT

mkdir -p "$(dirname "server/server.mjs")"
cat > server/server.mjs <<'EOF_RT'
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
    <div class="grid" id="mineGrid"></div>
  </section>
</main>
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
    if (me) { step("Confirm the listing in Freighter…"); id = await write("submit_item", A.addr(me), A.str(image_url)); }
    step("The appraiser is reading the marks and dating your piece… (about 20 seconds)");
    const res = await api("/appraise", id ? { id: Number(id) } : { image_url });
    showAppraisal(res);
    photos = []; $("#thumbs").innerHTML = "";
    if (!me) $("#sellNote").textContent = "Listed with the demo seller account. Connect Freighter to list under your own wallet.";
    load();
  } catch(err){ $("#appraisal").innerHTML = ""; toast(niceError(err), 6000); }
  btn.disabled = !photos.length;
};

load();
</script>
</body>
</html>
EOF_RT

cat > server/start.sh <<'EOF_RT'
#!/usr/bin/env bash
# Starts the AI appraiser in the background and makes it public
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd /workspaces/sansara
pkill -f "node server/server.mjs" 2>/dev/null || true
nohup node server/server.mjs > server/appraiser.log 2>&1 &
sleep 3
gh codespace ports visibility 8787:public -c "$CODESPACE_NAME" >/dev/null 2>&1 \
  && echo "Port 8787 is public" \
  || echo "Make port 8787 public: Ports tab > right-click 8787 > Port Visibility > Public"
curl -s localhost:8787/health; echo
tail -n 3 server/appraiser.log
EOF_RT
chmod +x server/start.sh
grep -q "server/.env" .gitignore 2>/dev/null || printf 'server/.env\nserver/appraiser.log\n' >> .gitignore

echo "== Tests =="
cargo test -q
stellar contract build

echo "== AI appraiser wallet =="
stellar keys generate appraiser --network testnet --fund 2>/dev/null || true
stellar keys generate seller --network testnet --fund 2>/dev/null || true

echo "== Deploying new contract =="
ID=$(stellar contract deploy --wasm $(ls target/wasm32*/release/marketplace.wasm | head -1) --source bazaar-admin --network testnet -- --admin bazaar-admin --token $(stellar contract id asset --asset native --network testnet) --fee_bps 250 --appraiser appraiser)
echo "CONTRACT: $ID"

URL="https://${CODESPACE_NAME}-8787.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
sed -i "s|CONTRACT_ID: \"[A-Z0-9]*\"|CONTRACT_ID: \"$ID\"|; s|APPRAISER_URL: \"[^\"]*\"|APPRAISER_URL: \"$URL\"|" web/index.html
mkdir -p docs/img && cp web/index.html docs/index.html

touch server/.env
grep -v '^CONTRACT_ID=' server/.env > server/.env.tmp || true
echo "CONTRACT_ID=$ID" >> server/.env.tmp && mv server/.env.tmp server/.env

git add -A && git commit -qm "AI appraiser: photo-only listings, AI sets price on-chain" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push -q

echo
echo "CONTRACT: $ID"
echo "APPRAISER: $URL"
echo "STEP 3 DONE"
