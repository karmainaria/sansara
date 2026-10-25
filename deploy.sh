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
