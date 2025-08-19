#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Load .env (CRLF-safe)
# -----------------------------
ENV_FILE=".env"
if [[ -f "$ENV_FILE" ]]; then
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

# Per-network router/WETH defaults (env can override)
: "${MAINNET_UNIV2_ROUTER:=0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D}"
: "${MAINNET_WETH:=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2}"

: "${SEPOLIA_UNIV2_ROUTER:=0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008}"
: "${SEPOLIA_WETH:=0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9}"

usage() {
  cat <<'USAGE'
TORC ops CLI
Usage:
  torc_ops.sh --network (mainnet|sepolia) --torc <TORC_ADDRESS> <command> [args]

Network/auth (read from .env):
  MAINNET_RPC_URL, SEPOLIA_RPC_URL
  PROD_DEPLOYER_PK (mainnet), TESTNET_DEPLOYER_PK (sepolia)

Router/WETH (can be overridden in .env):
  MAINNET_UNIV2_ROUTER, MAINNET_WETH
  SEPOLIA_UNIV2_ROUTER, SEPOLIA_WETH

Commands (admin/setup):
  setup:fee-split <addresses_json> <bps_json>
      Example:
        ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC \
          setup:fee-split '[0xAAA...,0xBBB...]' '[6000,4000]'

  setup:swap-fee <bps>
      Example:
        ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC setup:swap-fee 300

  setup:threshold <wei>
      Example:
        ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC setup:threshold 0

  setup:set-pair <pair_address>
      Example:
        ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC setup:set-pair 0xPairAddr...

  setup:set-router <router_address>
      Example:
        ./scripts/torc_ops.sh --network mainnet --torc 0xYourTORC setup:set-router 0xRouter...

  setup:set-weth <weth_address>
      Example:
        ./scripts/torc_ops.sh --network mainnet --torc 0xYourTORC setup:set-weth 0xWETH...

  setup:set-path <addresses_json>
      Example:
        ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC \
          setup:set-path '[0xYourTORC,0xWETH]'

Pausable:
  pause
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC pause

  unpause
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC unpause

Fee exemptions (FEE_MANAGER_ROLE):
  fee-exempt:add <address>
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC fee-exempt:add 0xUserAddr...

  fee-exempt:remove <address>
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC fee-exempt:remove 0xUserAddr...

TGE:
  tge:configure <recipients_json> <whole_amounts_json>
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC \
        tge:configure '[0xAlice,0xBob]' '[1000000,250000]'

  tge:execute
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC tge:execute

Fee conversion / distribution:
  fees:process [amountIn=0] [amountOutMin=0] [path_json="[]"] [deadline=+300s]
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC \
        fees:process 0 0 "[]" $(( $(date +%s) + 300 ))

  fees:distribute <amountWei>
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC fees:distribute 0

  fees:distribute-range <amountWei> <start> <end>
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC fees:distribute-range 1000000000000000000 0 2

  fees:claim
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC fees:claim

— LP / Uniswap V2 (ETH pairs) —
  lp:router-info
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC lp:router-info

  lp:get-pair [tokenB=<WETH autodetected>]
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC lp:get-pair

  lp:create-pair [tokenB=<WETH autodetected>]
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC lp:create-pair

  lp:add-eth <amountTokenDesired> <amountETH> [to=<deployer>] [amountTokenMin=0] [amountETHMin=0] [deadline=+300s]
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC \
        lp:add-eth 20000 50

  lp:remove-eth <liquidity> [to=<deployer>] [amountTokenMin=0] [amountETHMin=0] [deadline=+300s]
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC \
        lp:remove-eth 10

  lp:set-pair-on-torc [tokenB=<WETH autodetected>]
      ./scripts/torc_ops.sh --network sepolia --torc 0xYourTORC lp:set-pair-on-torc

USAGE
}

# --- Human → wei helpers (18 decimals) ---

# TORC amounts:
#   "1000"     -> 1000 * 1e18
#   "0.5"      -> 0.5 * 1e18
#   "123wei"   -> 123 (raw wei passthrough)
to_wei_token() {
  local x="$1"
  if [[ "$x" =~ ^([0-9]+)wei$ ]]; then
    echo "${BASH_REMATCH[1]}"; return
  fi
  python3 - "$x" <<'PY'
from decimal import Decimal, getcontext
import sys
getcontext().prec = 120
print(int(Decimal(sys.argv[1]) * (10 ** 18)))
PY
}

# ETH amounts:
#   "1"        -> 1 ether
#   "0.1"      -> 0.1 ether
#   "123wei"   -> 123 (raw wei)
to_wei_eth() {
  local x="$1"
  if [[ "$x" =~ ^([0-9]+)wei$ ]]; then
    echo "${BASH_REMATCH[1]}"; return
  fi
  python3 - "$x" <<'PY'
from decimal import Decimal, getcontext
import sys
getcontext().prec = 120
print(int(Decimal(sys.argv[1]) * (10 ** 18)))
PY
}

# --- helper to read decimals and balances (add near other helpers) ---
tok_decimals() { cast call "$TORC_ADDR" "decimals()(uint8)" --rpc-url "$RPC_URL"; }
tok_balance_of() { # $1 = address
  cast call "$TORC_ADDR" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC_URL"
}

preflight_lp_ok() {
  # $1 = tokenWei, $2 = ethWei
  python3 - "$1" "$2" <<'PY'
import sys, math
t = int(sys.argv[1]); e = int(sys.argv[2])
# UniswapV2 requires sqrt(t * e) > 1000 (MINIMUM_LIQUIDITY)
ok = int((t*e) ** 0.5) > 1000
print("OK" if ok else "SMALL")
PY
}

# (optional) supply tokens from a different provider
# If set in .env, these will be used when adding liquidity:
#   LP_PROVIDER_ADDR, LP_PROVIDER_PK
: "${LP_PROVIDER_ADDR:=}"
: "${LP_PROVIDER_PK:=}"

# Keep only the leading decimal digits from a cast output (e.g. "123 [1.23e2]" -> "123")
num() { printf '%s' "$1" | sed -E 's/[^0-9].*$//'; }

# Try to force decimal output; fall back to stripping the bracketed sci-notation.
cast_dec() {
  # Usage: cast_dec call <addr> "<sig>" [args...] --rpc-url "$RPC_URL"
  if OUT=$(cast "$@" --to-dec 2>/dev/null); then
    echo "$OUT"
  else
    # Fallback normalization: keep only the first space-delimited token
    OUT=$(cast "$@" 2>/dev/null || true)
    echo "${OUT%% *}"
  fi
}

# Pure bash normalizer (if you already have a value string)
dec_norm() {
  # Strips anything after the first space (e.g. "123 [1.23e2]" -> "123")
  local v="$1"
  echo "${v%% *}"
}

# ---- Uniswap pair helpers ----
get_router_addr() {
  if [[ "$NETWORK" == "mainnet" ]]; then
    echo "${UNIV2_ROUTER:?UNIV2_ROUTER missing}"
  else
    echo "${SEPOLIA_UNIV2_ROUTER:?SEPOLIA_UNIV2_ROUTER missing}"
  fi
}

get_weth_addr() {
  if [[ "$NETWORK" == "mainnet" ]]; then
    echo "${MAINNET_WETH:?MAINNET_WETH missing}"
  else
    echo "${SEPOLIA_WETH:?SEPOLIA_WETH missing}"
  fi
}

pair_addr_for() { # $1=tokenA $2=tokenB
  local ROUTER FACTORY
  ROUTER="$(get_router_addr)"
  FACTORY=$(cast call "$ROUTER" "factory()(address)" --rpc-url "$RPC_URL")
  cast call "$FACTORY" "getPair(address,address)(address)" "$1" "$2" --rpc-url "$RPC_URL"
}

pair_token0() { # $1=pair
  cast call "$1" "token0()(address)" --rpc-url "$RPC_URL"
}

pair_total_supply() { # $1=pair
  cast call "$1" "totalSupply()(uint256)" --rpc-url "$RPC_URL"
}

pair_reserves_raw() { # $1=pair
  # returns "r0 r1" as two lines
  cast call "$1" "getReserves()(uint112,uint112,uint32)" --rpc-url "$RPC_URL" | awk 'NR==1{print} NR==2{print}'
}

# Map reserves to TORC/WETH order
pair_reserves_torc_weth() { # $1=pair $2=TORC $3=WETH -> echo "rT rW"
  local T0 R0 R1
  T0=$(pair_token0 "$1")
  read -r R0 R1 < <(pair_reserves_raw "$1")
  if [[ "${T0,,}" == "${2,,}" ]]; then
    echo "$R0 $R1"    # token0 is TORC -> (r0,r1)
  else
    echo "$R1 $R0"    # token0 is WETH -> flip
  fi
}

# Python big-int/decimal compute helper
pycalc() { python3 - "$@"; }

# -------- Big-int helpers (Python; no sci-notation) --------
to_wei_18() {
  # $1 = whole units (e.g. "1000" TORC or "1" ETH)
  python3 - "$1" <<'PY'
import sys, decimal
decimal.getcontext().prec = 200
n = decimal.Decimal(sys.argv[1])
wei = int(n * (decimal.Decimal(10) ** 18))
print(wei)
PY
}

# Compare big integers: prints 1 if a < b else 0
big_lt() {
  python3 - "$1" "$2" <<'PY'
import sys
print(1 if int(sys.argv[1]) < int(sys.argv[2]) else 0)
PY
}

# Add/sub big integers (utility if you need later)
big_add() { python3 - "$1" "$2" <<< 'import sys; print(int(sys.argv[1]) + int(sys.argv[2]))'; }
big_sub() { python3 - "$1" "$2" <<< 'import sys; print(int(sys.argv[1]) - int(sys.argv[2]))'; }

# Nice-format for printing big ints (no brackets / no sci-notation)
fmt_dec() { python3 - "$1" <<< 'import sys; print(int(sys.argv[1]))'; }

# -----------------------------
# Parse top-level flags
# -----------------------------
NETWORK=""
TORC_ADDR=""
if [[ $# -lt 1 ]]; then usage; exit 1; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK="${2:-}"; shift 2;;
    --torc)    TORC_ADDR="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) break;;
  esac
done

CMD="${1:-}"; shift || true
if [[ -z "$NETWORK" || -z "$TORC_ADDR" || -z "$CMD" ]]; then usage; exit 1; fi

# -----------------------------
# Resolve RPC/PK and router/WETH
# -----------------------------
case "$NETWORK" in
  sepolia)
    : "${SEPOLIA_RPC_URL:?Set SEPOLIA_RPC_URL in .env}"
    : "${TESTNET_DEPLOYER_PK:?Set TESTNET_DEPLOYER_PK in .env}"
    RPC_URL="$SEPOLIA_RPC_URL"
    PK="$TESTNET_DEPLOYER_PK"
    ROUTER_ADDR="${SEPOLIA_UNIV2_ROUTER}"
    DEFAULT_WETH="${SEPOLIA_WETH}"
    ;;
  mainnet)
    : "${MAINNET_RPC_URL:?Set MAINNET_RPC_URL in .env}"
    : "${PROD_DEPLOYER_PK:?Set PROD_DEPLOYER_PK in .env}"
    RPC_URL="$MAINNET_RPC_URL"
    PK="$PROD_DEPLOYER_PK"
    ROUTER_ADDR="${MAINNET_UNIV2_ROUTER}"
    DEFAULT_WETH="${MAINNET_WETH}"
    ;;
  *)
    echo "Unknown --network '$NETWORK'"; exit 1;;
esac

say() { printf "\e[1;36m==>\e[0m %s\n" "$*"; }

# -----------------------------
# CAST wrappers
# -----------------------------
send() { # to TORC
  local SIG="$1"; shift || true
  cast send "$TORC_ADDR" "$SIG" "$@" --rpc-url "$RPC_URL" --private-key "$PK"
}

send_to() { # to arbitrary address
  local TO="$1"; shift
  local SIG="$1"; shift
  cast send "$TO" "$SIG" "$@" --rpc-url "$RPC_URL" --private-key "$PK"
}

call_to() { # read-only call
  local TO="$1"; shift
  local SIG="$1"; shift
  cast call "$TO" "$SIG" "$@" --rpc-url "$RPC_URL"
}

# -----------------------------
# Uniswap helpers
# -----------------------------
router_factory() { call_to "$ROUTER_ADDR" "factory()(address)"; }
router_weth()    { call_to "$ROUTER_ADDR" "WETH()(address)"; }

get_pair() {
  local FACTORY="$1"
  local TOKENA="$2"
  local TOKENB="$3"
  call_to "$FACTORY" "getPair(address,address)(address)" "$TOKENA" "$TOKENB"
}

approve_if_needed() { # token, spender, amount (wei)
  local TOKEN="$1"; local SPENDER="$2"; local AMOUNT="$3"
  local ALLOWANCE
  ALLOWANCE="$(call_to "$TOKEN" "allowance(address,address)(uint256)" "$(cast wallet address --private-key "$PK")" "$SPENDER")" || ALLOWANCE="0"
  if [[ "$ALLOWANCE" == "0x" || "$ALLOWANCE" == "0" ]]; then
    say "Approving $SPENDER to spend $AMOUNT on $TOKEN"
    send_to "$TOKEN" "approve(address,uint256)" "$SPENDER" "$AMOUNT"
  fi
}

# -----------------------------
# Command handlers
# -----------------------------
case "$CMD" in
  # ------- TORC admin -------
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

  pause)   say "pause()";   send "pause()";;
  unpause) say "unpause()"; send "unpause()";;

    roles:grant)
    ROLE_NAME="${1:?role name required}"
    ACCOUNT="${2:?account address required}"
    ROLE_HASH=$(cast keccak "$ROLE_NAME")
    say "Granting role $ROLE_NAME ($ROLE_HASH) to $ACCOUNT"
    send "grantRole(bytes32,address)" "$ROLE_HASH" "$ACCOUNT"
    ;;

  roles:revoke)
    ROLE_NAME="${1:?role name required}"
    ACCOUNT="${2:?account address required}"
    ROLE_HASH=$(cast keccak "$ROLE_NAME")
    say "Revoking role $ROLE_NAME ($ROLE_HASH) from $ACCOUNT"
    send "revokeRole(bytes32,address)" "$ROLE_HASH" "$ACCOUNT"
    ;;

  roles:renounce)
    ROLE_NAME="${1:?role name required}"
    ACCOUNT="${2:?account address required}"
    ROLE_HASH=$(cast keccak "$ROLE_NAME")
    say "Renouncing role $ROLE_NAME ($ROLE_HASH) for $ACCOUNT"
    send "renounceRole(bytes32,address)" "$ROLE_HASH" "$ACCOUNT"
    ;;

  roles:check)
    ROLE_NAME="${1:?role name required}"
    ACCOUNT="${2:?account address required}"
    ROLE_HASH=$(cast keccak "$ROLE_NAME")
    say "Checking role $ROLE_NAME ($ROLE_HASH) for $ACCOUNT"
    HAS_ROLE=$(cast call "$TORC_ADDR" "hasRole(bytes32,address)(bool)" "$ROLE_HASH" "$ACCOUNT" --rpc-url "$RPC_URL")
    echo "$ACCOUNT has $ROLE_NAME? $HAS_ROLE"
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

  # ------- LP / Uniswap V2 -------
  lp:router-info)
    say "Router     : $ROUTER_ADDR"
    FCT="$(router_factory)"; WETH_ADDR="$(router_weth)"
    say "Factory    : $FCT"
    say "Router WETH: $WETH_ADDR"
    ;;

  lp:get-pair)
    TOKENB="${1:-$DEFAULT_WETH}"
    FCT="$(router_factory)"
    PAIR="$(get_pair "$FCT" "$TORC_ADDR" "$TOKENB")"
    say "getPair(TORC,$TOKENB) => $PAIR"
    ;;

  lp:create-pair)
    TOKENB="${1:-$DEFAULT_WETH}"
    FCT="$(router_factory)"
    say "factory.createPair(TORC,$TOKENB)"
    NEW_PAIR="$(send_to "$FCT" "createPair(address,address)" "$TORC_ADDR" "$TOKENB" | awk '/transactionHash/ {print $2}')"
    # Fetch address after creation:
    PAIR="$(get_pair "$FCT" "$TORC_ADDR" "$TOKENB")"
    say "Pair created: $PAIR"
    ;;

  lp:add-eth)
    # Args:
    #   1: amountTokenDesired (human, e.g. 2.0 -> 2 TORC)
    #   2: amountETH          (human, e.g. 0.5 -> 0.5 ETH)
    #   3: to                 (optional; defaults to signer)
    #   4: amountTokenMin     (default 0)
    #   5: amountETHMin       (default 0)
    #   6: deadline           (default now+300s)
  HUMAN_TORC="${1:?amountTokenDesired (whole TORC) required}"
    HUMAN_ETH="${2:?amountETH (whole ETH) required}"

    TO="${3:-$(cast wallet address --private-key "$PK")}"
    AMOUNT_TOKEN_MIN_WEI="${4:-0}"   # you can keep 0 for testnet or pass a wei override
    AMOUNT_ETH_MIN_WEI="${5:-0}"
    DEADLINE="${6:-$(( $(date +%s) + 300 ))}"

    # Convert to wei using Python (handles huge ints precisely)
    AMOUNT_TOKEN_DESIRED_WEI="$(to_wei_18 "$HUMAN_TORC")"
    AMOUNT_ETH_WEI="$(to_wei_18 "$HUMAN_ETH")"

    # Resolve router by network
    if [[ "$NETWORK" == "mainnet" ]]; then
      ROUTER_ADDR="$UNIV2_ROUTER"
      WETH_ADDR="$MAINNET_WETH"
    else
      ROUTER_ADDR="$SEPOLIA_UNIV2_ROUTER"
      WETH_ADDR="$SEPOLIA_WETH"
    fi

    # Preflight balances (raw decimals; no sci-notation)
    DEPLOYER_ADDR="$(cast wallet address --private-key "$PK")"
    SUP_TORC_BAL="$(cast call "$TORC_ADDR" "balanceOf(address)(uint256)" "$DEPLOYER_ADDR" --rpc-url "$RPC_URL")"
    SUP_ETH_BAL="$(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL")"

    echo "=== LP add preflight ==="
    echo " Deployer           : $DEPLOYER_ADDR"
    echo " Router             : $ROUTER_ADDR"
    echo " Token (TORC)       : $TORC_ADDR"
    echo " WETH               : $WETH_ADDR"
    echo " Receiver (to)      : $TO"
    echo " TORC desired       : ${HUMAN_TORC} TORC = $(fmt_dec "$AMOUNT_TOKEN_DESIRED_WEI") wei"
    echo " ETH desired        : ${HUMAN_ETH} ETH  = $(fmt_dec "$AMOUNT_ETH_WEI") wei"
    echo " TORC balance       : $(fmt_dec "$SUP_TORC_BAL") wei"
    echo " ETH  balance       : $(fmt_dec "$SUP_ETH_BAL") wei"
    echo " Min TORC (wei)     : $AMOUNT_TOKEN_MIN_WEI"
    echo " Min ETH  (wei)     : $AMOUNT_ETH_MIN_WEI"
    echo " Deadline           : $DEADLINE"
    echo "========================"

    # Guard rails with big-int comparisons
    if [[ "$(big_lt "$SUP_TORC_BAL" "$AMOUNT_TOKEN_DESIRED_WEI")" == "1" ]]; then
      echo "ERROR: Insufficient TORC. Have $(fmt_dec "$SUP_TORC_BAL") wei, need $(fmt_dec "$AMOUNT_TOKEN_DESIRED_WEI") wei." >&2
      exit 1
    fi
    if [[ "$(big_lt "$SUP_ETH_BAL" "$AMOUNT_ETH_WEI")" == "1" ]]; then
      echo "ERROR: Insufficient ETH. Have $(fmt_dec "$SUP_ETH_BAL") wei, need $(fmt_dec "$AMOUNT_ETH_WEI") wei." >&2
      exit 1
    fi

    # Optional: show the Uniswap math expectation (just a note)
    echo ">>> This will call router.addLiquidityETH(TORC, tokenDesired, minToken, minETH, to, deadline) with:"
    echo "    tokenDesired=$(fmt_dec "$AMOUNT_TOKEN_DESIRED_WEI") wei, eth=$(fmt_dec "$AMOUNT_ETH_WEI") wei"

    # Approve TORC to the router (max makes future calls cheaper; or approve exact)
    echo "==> Approving router for TORC (max)..."
    cast send "$TORC_ADDR" "approve(address,uint256)" "$ROUTER_ADDR" 0 --rpc-url "$RPC_URL" --private-key "$PK" >/dev/null
    cast send "$TORC_ADDR" "approve(address,uint256)" "$ROUTER_ADDR" $(fmt_dec "$AMOUNT_TOKEN_DESIRED_WEI") --rpc-url "$RPC_URL" --private-key "$PK" >/dev/null
    # If you prefer MAX allowance:
    # cast send "$TORC_ADDR" "approve(address,uint256)" "$ROUTER_ADDR" 0 --rpc-url "$RPC_URL" --private-key "$PK"
    # cast send "$TORC_ADDR" "approve(address,uint256)" "$ROUTER_ADDR" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff --rpc-url "$RPC_URL" --private-key "$PK"

    echo "==> Adding liquidity (TORC + ETH)"
    cast send "$ROUTER_ADDR" \
      "addLiquidityETH(address,uint256,uint256,uint256,address,uint256)" \
      "$TORC_ADDR" "$(fmt_dec "$AMOUNT_TOKEN_DESIRED_WEI")" "$AMOUNT_TOKEN_MIN_WEI" "$AMOUNT_ETH_MIN_WEI" "$TO" "$DEADLINE" \
      --value "$(fmt_dec "$AMOUNT_ETH_WEI")" --rpc-url "$RPC_URL" --private-key "$PK"
    ;;

  lp:remove-eth)
    # Usage:
    #   lp:remove-eth all
    #   lp:remove-eth <liquidity> [to] [amountTokenMinWei=0] [amountETHMinWei=0] [deadline=+300s]
    #
    # <liquidity> can be:
    #   - "all"      -> remove your full LP balance
    #   - number     -> whole LP units with 18 decimals (e.g., "1.25" means 1.25 LP)
    #   - "<n>wei"   -> raw wei amount (e.g., "12345wei")

    WANT="${1:?liquidity (or 'all') required}"
    TO="${2:-$(cast wallet address --private-key "$PK")}"
    AMOUNT_TOKEN_MIN_WEI="${3:-0}"
    AMOUNT_ETH_MIN_WEI="${4:-0}"
    DEADLINE="${5:-$(( $(date +%s) + 300 ))}"

    # Resolve router per network
    if [[ "$NETWORK" == "mainnet" ]]; then
      ROUTER_ADDR="${UNIV2_ROUTER:?Set UNIV2_ROUTER in .env}"
      WETH_ADDR="${MAINNET_WETH:?Set MAINNET_WETH in .env}"
    else
      ROUTER_ADDR="${SEPOLIA_UNIV2_ROUTER:?Set SEPOLIA_UNIV2_ROUTER in .env}"
      WETH_ADDR="${SEPOLIA_WETH:?Set SEPOLIA_WETH in .env}"
    fi

    # Helpers
    _to_wei_generic() {
      local x="$1"
      if [[ "$x" =~ ^([0-9]+)wei$ ]]; then
        echo "${BASH_REMATCH[1]}"; return
      fi
      # treat as whole LP units (18 decimals)
      python3 - "$x" <<'PY'
from decimal import Decimal, getcontext
import sys
getcontext().prec = 120
print(int(Decimal(sys.argv[1]) * (10 ** 18)))
PY
    }

    # Discover factory & pair
    FACTORY_ADDR=$(cast call "$ROUTER_ADDR" "factory()(address)" --rpc-url "$RPC_URL" | tr -d '[:space:]')
    PAIR_ADDR=$(cast call "$FACTORY_ADDR" "getPair(address,address)(address)" "$TORC_ADDR" "$WETH_ADDR" --rpc-url "$RPC_URL" | tr -d '[:space:]')
    if [[ "$PAIR_ADDR" == "0x0000000000000000000000000000000000000000" ]]; then
      echo "No TORC/WETH pair exists yet. Create it first."; exit 1
    fi

    # Resolve signer & balances
    WALLET_ADDR=$(cast wallet address --private-key "$PK" | tr -d '[:space:]')
    LP_BALANCE_WEI=$(cast call "$PAIR_ADDR" "balanceOf(address)(uint256)" "$WALLET_ADDR" --rpc-url "$RPC_URL" | tr -d '[:space:]')

    # Determine LIQUIDITY in wei
    if [[ "$WANT" == "all" ]]; then
      LIQUIDITY="$LP_BALANCE_WEI"
      [[ "$LIQUIDITY" != "0" ]] || { echo "You have zero LP tokens."; exit 1; }
    else
      LIQUIDITY=$(_to_wei_generic "$WANT")
      # Guard: have enough LP?
      if [[ "$(big_lt "$LP_BALANCE_WEI" "$LIQUIDITY")" == "1" ]]; then
        echo "ERROR: Insufficient LP. Have $(fmt_dec "$LP_BALANCE_WEI") wei, need $(fmt_dec "$LIQUIDITY") wei." >&2
        exit 1
      fi
    fi

    # Preflight
    echo "=== LP remove preflight (standard) ==="
    echo " Deployer           : $WALLET_ADDR"
    echo " Router             : $ROUTER_ADDR"
    echo " Pair (LP token)    : $PAIR_ADDR"
    echo " TORC               : $TORC_ADDR"
    echo " WETH               : $WETH_ADDR"
    echo " LP balance (wei)   : $(fmt_dec "$LP_BALANCE_WEI")"
    echo " Remove (wei)       : $(fmt_dec "$LIQUIDITY")"
    echo " Min TORC (wei)     : $AMOUNT_TOKEN_MIN_WEI"
    echo " Min ETH  (wei)     : $AMOUNT_ETH_MIN_WEI"
    echo " Receiver (to)      : $TO"
    echo " Deadline           : $DEADLINE"
    echo "======================================"

    # Approve router to pull LP tokens
    say "Approving router for LP (pair) tokens..."
    cast send "$PAIR_ADDR" "approve(address,uint256)" "$ROUTER_ADDR" 0 \
      --rpc-url "$RPC_URL" --private-key "$PK" >/dev/null
    cast send "$PAIR_ADDR" "approve(address,uint256)" "$ROUTER_ADDR" "$(fmt_dec "$LIQUIDITY")" \
      --rpc-url "$RPC_URL" --private-key "$PK" >/dev/null

    # Remove liquidity (standard)
    say "Removing liquidity via router.removeLiquidityETH(...)"
    cast send "$ROUTER_ADDR" \
      "removeLiquidityETH(address,uint256,uint256,uint256,address,uint256)" \
      "$TORC_ADDR" "$(fmt_dec "$LIQUIDITY")" "$AMOUNT_TOKEN_MIN_WEI" "$AMOUNT_ETH_MIN_WEI" "$TO" "$DEADLINE" \
      --rpc-url "$RPC_URL" --private-key "$PK"
    ;;

  lp:remove-eth-supporting)
    # Same as above, but uses removeLiquidityETHSupportingFeeOnTransferTokens
    WANT="${1:?liquidity (or 'all') required}"
    TO="${2:-$(cast wallet address --private-key "$PK")}"
    AMOUNT_TOKEN_MIN_WEI="${3:-0}"
    AMOUNT_ETH_MIN_WEI="${4:-0}"
    DEADLINE="${5:-$(( $(date +%s) + 300 ))}"

    if [[ "$NETWORK" == "mainnet" ]]; then
      ROUTER_ADDR="${UNIV2_ROUTER:?Set UNIV2_ROUTER in .env}"
      WETH_ADDR="${MAINNET_WETH:?Set MAINNET_WETH in .env}"
    else
      ROUTER_ADDR="${SEPOLIA_UNIV2_ROUTER:?Set SEPOLIA_UNIV2_ROUTER in .env}"
      WETH_ADDR="${SEPOLIA_WETH:?Set SEPOLIA_WETH in .env}"
    fi

    _to_wei_generic() {
      local x="$1"
      if [[ "$x" =~ ^([0-9]+)wei$ ]]; then
        echo "${BASH_REMATCH[1]}"; return
      fi
      python3 - "$x" <<'PY'
from decimal import Decimal, getcontext
import sys
getcontext().prec = 120
print(int(Decimal(sys.argv[1]) * (10 ** 18)))
PY
    }

    FACTORY_ADDR=$(cast call "$ROUTER_ADDR" "factory()(address)" --rpc-url "$RPC_URL" | tr -d '[:space:]')
    PAIR_ADDR=$(cast call "$FACTORY_ADDR" "getPair(address,address)(address)" "$TORC_ADDR" "$WETH_ADDR" --rpc-url "$RPC_URL" | tr -d '[:space:]')
    if [[ "$PAIR_ADDR" == "0x0000000000000000000000000000000000000000" ]]; then
      echo "No TORC/WETH pair exists yet. Create it first."; exit 1
    fi

    WALLET_ADDR=$(cast wallet address --private-key "$PK" | tr -d '[:space:]')
    LP_BALANCE_WEI=$(cast call "$PAIR_ADDR" "balanceOf(address)(uint256)" "$WALLET_ADDR" --rpc-url "$RPC_URL" | tr -d '[:space:]')

    if [[ "$WANT" == "all" ]]; then
      LIQUIDITY="$LP_BALANCE_WEI"
      [[ "$LIQUIDITY" != "0" ]] || { echo "You have zero LP tokens."; exit 1; }
    else
      LIQUIDITY=$(_to_wei_generic "$WANT")
      if [[ "$(big_lt "$LP_BALANCE_WEI" "$LIQUIDITY")" == "1" ]]; then
        echo "ERROR: Insufficient LP. Have $(fmt_dec "$LP_BALANCE_WEI") wei, need $(fmt_dec "$LIQUIDITY") wei." >&2
        exit 1
      fi
    fi

    echo "=== LP remove preflight (supporting FOT) ==="
    echo " Deployer           : $WALLET_ADDR"
    echo " Router             : $ROUTER_ADDR"
    echo " Pair (LP token)    : $PAIR_ADDR"
    echo " TORC               : $TORC_ADDR"
    echo " WETH               : $WETH_ADDR"
    echo " LP balance (wei)   : $(fmt_dec "$LP_BALANCE_WEI")"
    echo " Remove (wei)       : $(fmt_dec "$LIQUIDITY")"
    echo " Min TORC (wei)     : $AMOUNT_TOKEN_MIN_WEI"
    echo " Min ETH  (wei)     : $AMOUNT_ETH_MIN_WEI"
    echo " Receiver (to)      : $TO"
    echo " Deadline           : $DEADLINE"
    echo "==========================================="

    say "Approving router for LP (pair) tokens..."
    cast send "$PAIR_ADDR" "approve(address,uint256)" "$ROUTER_ADDR" 0 \
      --rpc-url "$RPC_URL" --private-key "$PK" >/dev/null
    cast send "$PAIR_ADDR" "approve(address,uint256)" "$ROUTER_ADDR" "$(fmt_dec "$LIQUIDITY")" \
      --rpc-url "$RPC_URL" --private-key "$PK" >/dev/null

    say "Removing liquidity via router.removeLiquidityETHSupportingFeeOnTransferTokens(...)"
    cast send "$ROUTER_ADDR" \
      "removeLiquidityETHSupportingFeeOnTransferTokens(address,uint256,uint256,uint256,address,uint256)" \
      "$TORC_ADDR" "$(fmt_dec "$LIQUIDITY")" "$AMOUNT_TOKEN_MIN_WEI" "$AMOUNT_ETH_MIN_WEI" "$TO" "$DEADLINE" \
      --rpc-url "$RPC_URL" --private-key "$PK"
    ;;


  lp:set-pair-on-torc)
    TOKENB="${1:-$DEFAULT_WETH}"
    FCT="$(router_factory)"
    PAIR="$(get_pair "$FCT" "$TORC_ADDR" "$TOKENB")"
    if [[ "$PAIR" == "0x0000000000000000000000000000000000000000" ]]; then
      echo "Pair does not exist. Use lp:create-pair first."; exit 1
    fi
    say "TORC.setPairAddress($PAIR)"
    send "setPairAddress(address)" "$PAIR"
    ;;

  *)
    echo "Unknown command: $CMD"
    usage
    exit 1
    ;;
esac
