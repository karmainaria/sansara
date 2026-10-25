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
