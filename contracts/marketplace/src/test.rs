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
