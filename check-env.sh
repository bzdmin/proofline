#!/usr/bin/env bash
# Verifies .env without ever printing a private key.
set -uo pipefail
export PATH="$PATH:$HOME/.foundry/bin"
set -a; source ./.env; set +a

fail=0

echo "=== networks ==="
sc=$(cast chain-id --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo FAILED)
cc=$(cast chain-id --rpc-url "$CC3_RPC_URL"     2>/dev/null || echo FAILED)
[ "$sc" = "11155111" ] && echo "  sepolia  chain $sc  ok" || { echo "  sepolia  chain $sc  EXPECTED 11155111"; fail=1; }
[ "$cc" = "102031" ]   && echo "  cc3      chain $cc    ok" || { echo "  cc3      chain $cc  EXPECTED 102031"; fail=1; }

echo ""
echo "=== main wallet  (borrower + deployer, needs both) ==="
if [ -z "${PRIVATE_KEY:-}" ] || [ "$PRIVATE_KEY" = "0x" ]; then
  echo "  PRIVATE_KEY not set in .env"; fail=1
else
  A=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null || echo INVALID)
  echo "  address      $A"
  if [ "$A" != "INVALID" ]; then
    se=$(cast balance "$A" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo 0)
    ce=$(cast balance "$A" --rpc-url "$CC3_RPC_URL"     2>/dev/null || echo 0)
    echo "  sepolia ETH  $(cast from-wei "$se")"
    echo "  cc3     CTC  $(cast from-wei "$ce")"
    [ "$se" = "0" ] && { echo "  ^ Sepolia faucet has not landed"; fail=1; }
    [ "$ce" = "0" ] && { echo "  ^ CC3 faucet has not landed"; fail=1; }
  else
    echo "  key is malformed"; fail=1
  fi
fi

echo ""
echo "=== relayer wallet  (CC3 only, for Q4) ==="
if [ -z "${RELAYER_PRIVATE_KEY:-}" ] || [ "$RELAYER_PRIVATE_KEY" = "0x" ]; then
  echo "  not set - Q1-Q3 fine, Q4 blocked"
else
  B=$(cast wallet address --private-key "$RELAYER_PRIVATE_KEY" 2>/dev/null || echo INVALID)
  echo "  address      $B"
  if [ "$B" = "${A:-}" ]; then echo "  ^ SAME as main wallet - Q4 needs an unrelated address"; fail=1; fi
  if [ "$B" != "INVALID" ]; then
    rc=$(cast balance "$B" --rpc-url "$CC3_RPC_URL" 2>/dev/null || echo 0)
    echo "  cc3     CTC  $(cast from-wei "$rc")"
    [ "$rc" = "0" ] && echo "  ^ no CTC yet - Q4 blocked"
  fi
fi

echo ""
[ "$fail" = "0" ] && echo "READY for G0-A." || echo "NOT READY - see above."
