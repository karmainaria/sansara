#!/usr/bin/env bash
# Build, test and deploy the Relic & Thread contract to Stellar testnet.
# Needs: Rust (wasm32v1-none target) and the stellar CLI.
set -euo pipefail

NETWORK=testnet
ADMIN=${ADMIN:-bazaar-admin}      # receives the platform fee, resolves disputes
APPRAISER=${APPRAISER:-appraiser} # AI agent key: the only one allowed to set prices
FEE_BPS=${FEE_BPS:-250}           # 2.5%

for k in "$ADMIN" "$APPRAISER"; do
  stellar keys generate "$k" --network "$NETWORK" --fund 2>/dev/null || true
done

cargo test
stellar contract build
WASM=$(ls target/wasm32*/release/marketplace.wasm | head -1)

# payment token: native XLM (use a USDC SAC address for stablecoins)
TOKEN=$(stellar contract id asset --asset native --network "$NETWORK")

CONTRACT_ID=$(stellar contract deploy \
  --wasm "$WASM" --source "$ADMIN" --network "$NETWORK" \
  -- --admin "$ADMIN" --token "$TOKEN" --fee_bps "$FEE_BPS" --appraiser "$APPRAISER")

echo
echo "CONTRACT_ID=$CONTRACT_ID"
echo "Put it in server/.env and in web/index.html → CONFIG.CONTRACT_ID"
