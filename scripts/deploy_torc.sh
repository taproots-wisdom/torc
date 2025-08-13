#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Load .env (robustly, even if CRLF)
# -----------------------------
ENV_FILE=".env"
if [[ -f "$ENV_FILE" ]]; then
  # Strip CRs to avoid `$'\r': command not found`
  eval "$(
    sed -e 's/\r$//' "$ENV_FILE" \
    | grep -v '^\s*#' \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' \
    | sed -e 's/^/export /'
  )"
fi

# -----------------------------
# Defaults & constants
# -----------------------------
NETWORK=""
BROADCAST="no"
VERIFY_ON_DEPLOY="no"
VERBOSITY="-vv"
INTERACTIVE="yes"
VERIFY_ADDRESS=""   # used by --verify <addr>

# Fully-qualified name for verification
FQN="src/TORC.sol:TORC"

# Known addresses
MAINNET_WETH="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
MAINNET_UNIV2_ROUTER="0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"

SEPOLIA_WETH="0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9"
SEPOLIA_UNIV2_ROUTER="0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008"

# -----------------------------
# Helpers
# -----------------------------
usage() {
  cat <<EOF
Usage:
  $0 --network <mainnet|sepolia> [--broadcast] [--verify-on-deploy] [--no-prompt] [--verbosity -vv]
  $0 --network <mainnet|sepolia> --verify <deployed_address>

Env vars expected in .env:
  MAINNET_RPC_URL, SEPOLIA_RPC_URL
  PROD_DEPLOYER_PK (for mainnet), TESTNET_DEPLOYER_PK (for sepolia)
  ETHERSCAN_API_KEY (required for verification)

Examples:
  # Dry-run deploy to sepolia
  $0 --network sepolia

  # Broadcast deploy to sepolia + auto-verify after deploy
  $0 --network sepolia --broadcast --verify-on-deploy --no-prompt

  # Verify an already-deployed mainnet contract
  $0 --network mainnet --verify 0xDeployedAddress
EOF
  exit 1
}

prompt_yes() {
  local msg="$1"
  if [[ "$INTERACTIVE" == "no" ]]; then
    echo "AUTO-APPROVED: $msg"
    return 0
  fi
  read -r -p "$msg (y/N) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# -----------------------------
# Parse args
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK="${2:-}"; shift 2;;
    --broadcast) BROADCAST="yes"; shift;;
    --verify-on-deploy) VERIFY_ON_DEPLOY="yes"; shift;;
    --no-prompt) INTERACTIVE="no"; shift;;
    --verbosity) VERBOSITY="${2:-}"; shift 2;;
    --verify) VERIFY_ADDRESS="${2:-}"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

[[ -z "$NETWORK" ]] && { echo "ERROR: --network is required"; usage; }

# -----------------------------
# Network setup
# -----------------------------
if [[ "$NETWORK" == "mainnet" ]]; then
  RPC_URL="${MAINNET_RPC_URL:-}"
  PRIVATE_KEY="${PROD_DEPLOYER_PK:-}"
  CHAIN_ID=1
  WETH_ADDR="$MAINNET_WETH"
  ROUTER_ADDR="$MAINNET_UNIV2_ROUTER"
  SCRIPT_PATH="script/DeployTORC_Mainnet.s.sol:DeployTORC_Mainnet"
elif [[ "$NETWORK" == "sepolia" ]]; then
  RPC_URL="${SEPOLIA_RPC_URL:-}"
  PRIVATE_KEY="${TESTNET_DEPLOYER_PK:-}"
  CHAIN_ID=11155111
  WETH_ADDR="$SEPOLIA_WETH"
  ROUTER_ADDR="$SEPOLIA_UNIV2_ROUTER"
  SCRIPT_PATH="script/DeployTORC_Sepolia.s.sol:DeployTORC_Sepolia"
else
  echo "ERROR: unsupported network '$NETWORK'"; exit 1
fi

[[ -z "$RPC_URL" ]] && { echo "ERROR: ${NETWORK^^}_RPC_URL missing in .env"; exit 1; }

# -----------------------------
# Verify-only path
# -----------------------------
if [[ -n "$VERIFY_ADDRESS" ]]; then
  [[ -z "${ETHERSCAN_API_KEY:-}" ]] && { echo "ERROR: ETHERSCAN_API_KEY missing in .env"; exit 1; }

  echo "== Verifying TORC =="
  echo " Network     : $NETWORK"
  echo " Address     : $VERIFY_ADDRESS"
  echo " FQN         : $FQN"
  echo " Chain ID    : $CHAIN_ID"
  echo " Constructor : (address _weth, address _uniswapRouter)"
  echo "   _weth         = $WETH_ADDR"
  echo "   _uniswapRouter= $ROUTER_ADDR"
  echo

  # Encode constructor args
  CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" "$WETH_ADDR" "$ROUTER_ADDR")

  if ! prompt_yes "Proceed with verification?"; then
    echo "Aborted."
    exit 0
  fi

  forge verify-contract \
    --chain-id "$CHAIN_ID" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$CONSTRUCTOR_ARGS" \
    "$VERIFY_ADDRESS" \
    "$FQN"

  echo "Submitted verification. If it shows 'Pending in queue', give Etherscan a moment."
  exit 0
fi

# -----------------------------
# Deploy path (script)
# -----------------------------
echo "== Deploying TORC =="
echo " Network     : $NETWORK"
echo " Script      : $SCRIPT_PATH"
echo " Broadcast   : $BROADCAST"
echo " VerifyAuto  : $VERIFY_ON_DEPLOY"
echo " Verbosity   : $VERBOSITY"
echo
echo "Optional configuration from .env (if set):"
echo " FEE_RECIPIENT         : ${FEE_RECIPIENT:-0xYourTreasuryOrDeployer}"
echo " FEE_BPS               : ${FEE_BPS:-10000}"
echo " SWAP_FEE_BPS          : ${SWAP_FEE_BPS:-300}"
echo " FEE_THRESHOLD_WEI     : ${FEE_THRESHOLD_WEI:-0}"
echo " PAIR_ADDRESS          : ${PAIR_ADDRESS:-0x0000000000000000000000000000000000000000}"
echo " WETH                  : $WETH_ADDR"
echo " UNISWAP_V2_ROUTER     : $ROUTER_ADDR"
echo

if ! prompt_yes "Proceed?"; then
  echo "Aborted."
  exit 0
fi

ARGS=(forge script "$SCRIPT_PATH" --rpc-url "$RPC_URL" "$VERBOSITY")

if [[ "$BROADCAST" == "yes" ]]; then
  [[ -z "$PRIVATE_KEY" ]] && { echo "ERROR: missing deployer private key for $NETWORK"; exit 1; }
  ARGS+=(--private-key "$PRIVATE_KEY" --broadcast)
fi

if [[ "$VERIFY_ON_DEPLOY" == "yes" ]]; then
  [[ -z "${ETHERSCAN_API_KEY:-}" ]] && { echo "ERROR: ETHERSCAN_API_KEY missing in .env"; exit 1; }
  ARGS+=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
fi

# Pass environment vars through (forge reads them directly)
"${ARGS[@]}"
