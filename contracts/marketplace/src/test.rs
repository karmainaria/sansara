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
