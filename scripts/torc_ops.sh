#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Load .env (CRLF-safe)
# -----------------------------
ENV_FILE=".env"
if [[ -f "$ENV_FILE" ]]; then
  # Strip CRs (Windows line endings) into a temp file
  TMP_ENV="$(mktemp)"
  tr -d '\r' < "$ENV_FILE" > "$TMP_ENV"
  set -a
  # shellcheck source=/dev/null
  source "$TMP_ENV"
  set +a
  rm -f "$TMP_ENV"
fi

# -----------------------------
# Defaults / checks
# -----------------------------
: "${MAINNET_RPC_URL:=}"
: "${SEPOLIA_RPC_URL:=}"
: "${PROD_DEPLOYER_PK:=}"
: "${TESTNET_DEPLOYER_PK:=}"

usage() {
  cat <<'USAGE'
TORC ops CLI

Usage:
  torc_ops.sh --network (mainnet|sepolia) --torc <TORC_ADDRESS> <command> [args]

Network/auth (read from .env):
  MAINNET_RPC_URL, SEPOLIA_RPC_URL
  PROD_DEPLOYER_PK (mainnet), TESTNET_DEPLOYER_PK (sepolia)

Commands (admin/setup):
  setup:fee-split <addresses_json> <bps_json>
      Set fee recipients + BPS (sum must be 10000).
      Example:
        torc_ops.sh --network sepolia --torc 0xToken \
          setup:fee-split '["0xAAA","0xBBB"]' '[6000,4000]'

  setup:swap-fee <bps>
      Set swap fee in basis points (max 1000).
      Example: ... setup:swap-fee 300

  setup:threshold <wei>
      Set fee distribution threshold (wei).
      Example: ... setup:threshold 0

  setup:set-pair <pair_address>
      Set UniswapV2 pair address.

  setup:set-router <router_address>
      Update router (handles allowances flip).

  setup:set-weth <weth_address>
      Update WETH (default path tail auto-updated).

  setup:set-path <addresses_json>
      Set default swap path (must start with TORC, end with WETH).
      Example: ... setup:set-path '["0xToken","0xWETH"]'

Pausable:
  pause
  unpause

Fee exemptions (requires FEE_MANAGER_ROLE):
  fee-exempt:add <address>
  fee-exempt:remove <address>

TGE:
  tge:configure <recipients_json> <whole_amounts_json>
      Whole token amounts (no 1e18). Enforces cap.
      Example:
        ... tge:configure '["0xAlice","0xBob"]' '[1000000,250000]'
  tge:execute

Fee conversion / distribution (optional day‑to‑day):
  fees:process [amountIn=0] [amountOutMin=0] [path_json="[]"] [deadline=+300s]
      Example (use default path): ... fees:process 0 0 "[]" $(( $(date +%s) + 300 ))
      Example (explicit path):    ... fees:process 0 0 '["0xToken","0xWETH"]' $(( $(date +%s) + 300 ))

  fees:distribute <amountWei>
      Accrue+push up to amount (0 uses all accumulated).

  fees:distribute-range <amountWei> <start> <end>
      Accrue to recipients slice [start,end), no push.

  fees:claim
      Claim pending ETH for the signer account.

Examples:
  ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC pause
  ./scripts/torc_ops.sh --network mainnet  --torc 0xYourTORC setup:swap-fee 300

USAGE
}

# -----------------------------
# Parse top-level flags
# -----------------------------
NETWORK=""
TORC_ADDR=""
if [[ $# -lt 1 ]]; then usage; exit 1; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)
      NETWORK="${2:-}"; shift 2;;
    --torc)
      TORC_ADDR="${2:-}"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      break;;
  esac
done

CMD="${1:-}"; shift || true

if [[ -z "$NETWORK" || -z "$TORC_ADDR" || -z "$CMD" ]]; then
  usage; exit 1
fi

# -----------------------------
# Resolve RPC and PK
# -----------------------------
case "$NETWORK" in
  sepolia)
    : "${SEPOLIA_RPC_URL:?Set SEPOLIA_RPC_URL in .env}"
    : "${TESTNET_DEPLOYER_PK:?Set TESTNET_DEPLOYER_PK in .env}"
    RPC_URL="$SEPOLIA_RPC_URL"
    PK="$TESTNET_DEPLOYER_PK"
    ;;
  mainnet)
    : "${MAINNET_RPC_URL:?Set MAINNET_RPC_URL in .env}"
    : "${PROD_DEPLOYER_PK:?Set PROD_DEPLOYER_PK in .env}"
    RPC_URL="$MAINNET_RPC_URL"
    PK="$PROD_DEPLOYER_PK"
    ;;
  *)
    echo "Unknown --network '$NETWORK'"; exit 1;;
esac

# Pretty print helper
say() { printf "\e[1;36m==>\e[0m %s\n" "$*"; }

# -----------------------------
# CAST wrappers
# -----------------------------
send() {
  # $1 = signature, rest = args...
  local SIG="$1"; shift || true
  cast send "$TORC_ADDR" "$SIG" "$@" --rpc-url "$RPC_URL" --private-key "$PK"
}

# -----------------------------
# Command handlers
# -----------------------------

case "$CMD" in
  setup:fee-split)
    ADDR_JSON="${1:?addresses_json required}"
    BPS_JSON="${2:?bps_json required}"
    say "setFeeRecipients ${ADDR_JSON} ${BPS_JSON}"
    send "setFeeRecipients(address[],uint256[])" "$ADDR_JSON" "$BPS_JSON"
    ;;

  setup:swap-fee)
    BPS="${1:?bps required}"
    say "setSwapFee $BPS"
    send "setSwapFee(uint256)" "$BPS"
    ;;

  setup:threshold)
    WEI="${1:?wei required}"
    say "setFeeDistributionThreshold $WEI"
    send "setFeeDistributionThreshold(uint256)" "$WEI"
    ;;

  setup:set-pair)
    PAIR="${1:?pair address required}"
    say "setPairAddress $PAIR"
    send "setPairAddress(address)" "$PAIR"
    ;;

  setup:set-router)
    ROUTER="${1:?router address required}"
    say "setRouter $ROUTER"
    send "setRouter(address)" "$ROUTER"
    ;;

  setup:set-weth)
    WETH="${1:?weth address required}"
    say "setWETH $WETH"
    send "setWETH(address)" "$WETH"
    ;;

  setup:set-path)
    PATH_JSON="${1:?addresses_json required}"
    say "setDefaultSwapPath ${PATH_JSON}"
    send "setDefaultSwapPath(address[])" "$PATH_JSON"
    ;;

  pause)
    say "pause()"
    send "pause()"
    ;;

  unpause)
    say "unpause()"
    send "unpause()"
    ;;

  fee-exempt:add)
    WHO="${1:?address required}"
    say "setFeeExempt($WHO,true)"
    send "setFeeExempt(address,bool)" "$WHO" true
    ;;

  fee-exempt:remove)
    WHO="${1:?address required}"
    say "setFeeExempt($WHO,false)"
    send "setFeeExempt(address,bool)" "$WHO" false
    ;;

  tge:configure)
    RECIPIENTS_JSON="${1:?recipients_json required}"
    WHOLE_AMOUNTS_JSON="${2:?whole_amounts_json required}"
    say "configureTGE recipients=${RECIPIENTS_JSON} amounts=${WHOLE_AMOUNTS_JSON}"
    send "configureTGE(address[],uint256[])" "$RECIPIENTS_JSON" "$WHOLE_AMOUNTS_JSON"
    ;;

  tge:execute)
    say "executeTGE()"
    send "executeTGE()"
    ;;

  fees:process)
    AMOUNT_IN="${1:-0}"
    MIN_OUT="${2:-0}"
    PATH_JSON="${3:-[]}"
    DEADLINE="${4:-$(( $(date +%s) + 300 ))}"
    say "processFees(amountIn=$AMOUNT_IN, minOut=$MIN_OUT, deadline=$DEADLINE) path=$PATH_JSON"
    send "processFees(uint256,uint256,address[],uint256)" "$AMOUNT_IN" "$MIN_OUT" "$PATH_JSON" "$DEADLINE"
    ;;

  fees:distribute)
    AMOUNT_WEI="${1:-0}"
    say "distributeFees amount=$AMOUNT_WEI"
    send "distributeFees(uint256)" "$AMOUNT_WEI"
    ;;

  fees:distribute-range)
    AMOUNT_WEI="${1:?amount required}"
    START="${2:?start required}"
    END="${3:?end required}"
    say "distributeFeesRange amount=$AMOUNT_WEI range=[$START,$END)"
    send "distributeFeesRange(uint256,uint256,uint256)" "$AMOUNT_WEI" "$START" "$END"
    ;;

  fees:claim)
    say "claimFees()"
    send "claimFees()"
    ;;

  *)
    echo "Unknown command: $CMD"
    usage
    exit 1
    ;;
esac
