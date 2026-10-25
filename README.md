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
