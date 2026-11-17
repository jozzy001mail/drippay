#!/usr/bin/env bash
# DripPay deploy orchestrator — Reactive Omni Buildathon.
# Topology A (default): vault on Base Sepolia (84532) <-> reactive on Lasna (5318007).
# Topology B (fallback): both contracts on Lasna (set DEST_CHAIN_ID=5318007,
#   DEST_RPC=https://lasna-rpc.rnk.dev/, DEST_PROXY=0x8888888888888888888888888888888888888888).
#
# Funding needed BEFORE running (all testnet, $0 real money):
#   - Lasna lREACT for the deployer + the reactive contract's reserve.
#     Get Sepolia ETH (Google Cloud faucet, 0.05/day), then send >=0.02 ETH to
#     the Reactive faucet 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 (1 ETH = 100 lREACT).
#   - Destination-chain ETH for the deployer + the vault's reserve.
#     Base Sepolia: bridge Sepolia ETH at https://bridge.base.org, or use the
#     Alchemy Base Sepolia faucet.
# Usage:
#   cp .env.example .env   # fill in DEPLOYER_KEY (throwaway, testnet only)
#   ./script/deploy.sh            # cross-chain (Base Sepolia <-> Lasna)
#   DEST_CHAIN_ID=5318007 ./script/deploy.sh   # Lasna-only fallback
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:/home/hatch/.foundry/bin"

: "${DEPLOYER_KEY:?Set DEPLOYER_KEY in .env (throwaway testnet key only)}"
LASNA_RPC="${LASNA_RPC:-https://lasna-rpc.rnk.dev/}"
DEST_CHAIN_ID="${DEST_CHAIN_ID:-84532}"
DEST_RPC="${DEST_RPC:-https://sepolia.base.org}"
DEST_PROXY="${DEST_PROXY:-0x476F44b11F5C942c58f4c8E3d0300E5710743585}"
ORIGIN_CHAIN_ID="${ORIGIN_CHAIN_ID:-84532}"

DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
echo "Deployer: $DEPLOYER"
echo "Lasna lREACT balance: $(cast balance "$DEPLOYER" --rpc-url "$LASNA_RPC") wei"
echo "Dest chain balance:   $(cast balance "$DEPLOYER" --rpc-url "$DEST_RPC") wei"

# The vault will be the deployer's NEXT transaction on the destination chain,
# so its address is predictable — the reactive contract needs it at construction.
DEST_NONCE=$(cast nonce "$DEPLOYER" --rpc-url "$DEST_RPC")
VAULT_ADDR=$(cast compute-address "$DEPLOYER" --nonce "$DEST_NONCE" --rpc-url "$DEST_RPC" | awk '{print $NF}')
echo "Predicted vault address: $VAULT_ADDR (dest nonce $DEST_NONCE)"

echo "--- Deploying DripReactive on Lasna ---"
VAULT_ADDR="$VAULT_ADDR" ORIGIN_CHAIN_ID="$ORIGIN_CHAIN_ID" DESTINATION_CHAIN_ID="$DEST_CHAIN_ID" \
  forge script script/DeployReactive.s.sol --rpc-url "$LASNA_RPC" \
  --private-key "$DEPLOYER_KEY" --broadcast --chain-id 5318007 2>&1 | tee /tmp/drippay-deploy-reactive.log
REACTIVE_ADDR=$(grep -oP 'DripReactive deployed at: \K0x[0-9a-fA-F]{40}' /tmp/drippay-deploy-reactive.log | head -1)
echo "Reactive: $REACTIVE_ADDR"

echo "--- Deploying DripVault on chain $DEST_CHAIN_ID ---"
REACTIVE_ADDR="$REACTIVE_ADDR" PROXY_ADDR="$DEST_PROXY" \
  forge script script/DeployVault.s.sol --rpc-url "$DEST_RPC" \
  --private-key "$DEPLOYER_KEY" --broadcast --chain-id "$DEST_CHAIN_ID" 2>&1 | tee /tmp/drippay-deploy-vault.log
DEPLOYED_VAULT=$(grep -oP 'DripVault deployed at: \K0x[0-9a-fA-F]{40}' /tmp/drippay-deploy-vault.log | head -1)
echo "Vault: $DEPLOYED_VAULT"

if [ "$DEPLOYED_VAULT" != "$VAULT_ADDR" ]; then
  echo "WARNING: vault landed at $DEPLOYED_VAULT, not the predicted $VAULT_ADDR."
  echo "Pointing the reactive contract at the real vault..."
  cast send "$REACTIVE_ADDR" "setVault(address)" "$DEPLOYED_VAULT" \
    --rpc-url "$LASNA_RPC" --private-key "$DEPLOYER_KEY"
  VAULT_ADDR="$DEPLOYED_VAULT"
fi

echo "--- Verifying ---"
echo "Vault nextScheduleId: $(cast call "$VAULT_ADDR" "nextScheduleId()(uint256)" --rpc-url "$DEST_RPC")"
echo "Reactive vault:       $(cast call "$REACTIVE_ADDR" "vault()(address)" --rpc-url "$LASNA_RPC")"
echo "Reactive destination: $(cast call "$REACTIVE_ADDR" "destinationChainId()(uint256)" --rpc-url "$LASNA_RPC")"
echo ""
echo "DripPay deployed:"
echo "  DripVault (chain $DEST_CHAIN_ID): $VAULT_ADDR"
echo "  DripReactive (Lasna 5318007):     $REACTIVE_ADDR"
echo "Save these in app/src/config.js and SUBMISSION.md."
