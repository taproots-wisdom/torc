#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
TORC ops CLI (Python)
- Precise big-int math (Decimal)
- CRLF-safe .env loader (no extra deps)
- Wraps `cast` for send/call
- Supports admin, fees, roles, TGE, and LP (UniswapV2) ops

This module exposes a command line interface for interacting with the TORC
token and its associated liquidity pool on Uniswap V2.  It relies on
`cast` from the Foundry toolkit to perform RPC calls.  The CLI covers
administrative functions (e.g. setting fee recipients), fee processing,
role management, TGE configuration, and liquidity operations.  See the
argument parser in the bottom half of this file for a complete list of
supported sub‑commands.

The `lp:add-eth` command originally treated the `amountTokenMin` and
`amountETHMin` parameters as raw integers without converting them from
human readable amounts into wei.  This meant that a value like `"100"`
was interpreted as **100 wei** rather than **100 tokens**.  Since 1 token
typically equals 10^18 wei for ERC‑20 tokens with 18 decimals, the
script ended up adding 10^18 fewer tokens than expected.  To fix this,
the minimum amounts are now converted using `to_wei_18`, just like
`amountTokenDesired` and `amountETH`.

Usage examples:
  ./torc_ops.py --network sepolia --torc 0xYourTORC pause
  ./torc_ops.py --network sepolia --torc 0xYourTORC setup:fee-split '["0xAAA","0xBBB"]' "[6000,4000]"
  ./torc_ops.py --network sepolia --torc 0xYourTORC lp:router-info
  ./torc_ops.py --network sepolia --torc 0xYourTORC lp:add-eth 20000 50
  ./torc_ops.py --network sepolia --torc 0xYourTORC lp:remove-eth all
"""

import argparse
import json
from numbers import Number
import os
import shlex
import subprocess
import sys
from decimal import Decimal, getcontext

getcontext().prec = 200  # high precision for 1e18 arithmetic

# ------------- .env loader (CRLF-safe, no deps) -------------
def load_env(path: str = ".env"):
    """Load environment variables from a .env file.

    Parameters
    ----------
    path: str
        Path to the .env file.  Lines starting with '#' are ignored.  CR
        characters are stripped to support both LF and CRLF line endings.

    Notes
    -----
    Existing environment variables are not overwritten.
    """
    if not os.path.isfile(path):
        return
    with open(path, "rb") as f:
        raw = f.read().replace(b"\r", b"")
    for line in raw.decode("utf-8", "ignore").split("\n"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        # do not overwrite existing environment
        os.environ.setdefault(k, v)


load_env()

# ------------- Defaults -------------
MAINNET_UNIV2_ROUTER = os.environ.get("MAINNET_UNIV2_ROUTER", "0xe82Bcb6d75Ec304D2447B587Dee01A0D5aB25785")
MAINNET_WETH = os.environ.get("MAINNET_WETH", "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
SEPOLIA_UNIV2_ROUTER = os.environ.get("SEPOLIA_UNIV2_ROUTER", "0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008")
SEPOLIA_WETH = os.environ.get("SEPOLIA_WETH", "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9")

# ------------- Utils -------------
def die(msg, code=1):
    """Print an error message and exit with the given code."""
    print(msg, file=sys.stderr)
    sys.exit(code)


def say(msg):
    """Print a status message prefixed with a cyan arrow."""
    print(f"\033[1;36m==>\033[0m {msg}")


def run(args, capture=True):
    """Run a shell command; return stdout string or raise on failure.

    Parameters
    ----------
    args: list[str] | str
        Command to execute.  If a string is provided it is tokenised
        via `shlex.split`.
    capture: bool, default True
        Whether to capture stdout.  If False, output is printed directly.

    Returns
    -------
    str
        Standard output stripped of trailing whitespace.
    """
    if isinstance(args, str):
        args = shlex.split(args)
    # We want errors to bubble up with context
    res = subprocess.run(args, stdout=subprocess.PIPE if capture else None, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        # include stderr for better diagnosis
        die(res.stderr.strip() or f"Command failed: {' '.join(args)}")
    return (res.stdout or "").strip()


def cast_call(rpc, to, sig, *args):
    """Wrapper around `cast call` returning only the raw result string."""
    cmd = ["cast", "call", to, sig, *map(str, args), "--rpc-url", rpc]
    out = run(cmd)
    # output may contain a pretty suffix like " 123 [1.23e2]"; keep first token
    return out.split()[0] if out else out


def cast_send(rpc, pk, to, sig, *args):
    """Wrapper around `cast send` for transactions."""
    cmd = ["cast", "send", to, sig, *map(str, args), "--rpc-url", rpc, "--private-key", pk]
    return run(cmd, capture=False)


def cast_wallet_address(pk):
    """Return the address derived from a private key via `cast wallet address`."""
    return run(["cast", "wallet", "address", "--private-key", pk]).split()[0]


def cast_balance(rpc, addr):
    """Return the ETH balance of an address via `cast balance`."""
    return run(["cast", "balance", addr, "--rpc-url", rpc]).split()[0]

def parse_bigint(s: str) -> int:
    s = s.strip().strip("[](),")
    if s.startswith(("0x", "-0x")):
        return int(s, 0)
    # Use Decimal for 'e' or '.' forms; int(Decimal) truncates toward 0
    if any(ch in s for ch in ("e", "E", ".")):
        return int(Decimal(s))
    return int(s)

def to_wei_18(human: str) -> int:
    """Convert human readable token/ETH amounts into wei (18 decimals).

    Accepts pure numbers like ``"123"`` (interpreted as whole units) or
    decimal numbers like ``"0.5"``.  If the string ends with ``"wei"``
    the value is returned verbatim (as an integer) without scaling.

    Parameters
    ----------
    human: str
        The human readable amount.

    Returns
    -------
    int
        The amount scaled by 10**18, unless suffixed with ``wei``.
    """
    s = human.strip()
    if s.endswith("wei"):
        return int(s[:-3])
    # Decimal multiplication provides reliable conversion for decimals
    return int(Decimal(s) * (Decimal(10) ** 18))

# New helper: convert an amount expressed in human units to the smallest
# denomination (wei) given the ERC‑20 decimals.  It behaves like
# ``to_wei_18`` but takes an explicit decimals argument.  If the
# string ends with ``wei`` the numeric portion is interpreted as a raw
# integer and returned unchanged.
def to_wei_with_decimals(human: str, decimals: int) -> int:
    s = human.strip()
    if s.endswith("wei"):
        return int(s[:-3])
    return int(Decimal(s) * (Decimal(10) ** decimals))

# Query decimals from an ERC‑20 token.  Cast returns a hex or decimal
# string; both are supported.
def token_decimals(rpc: str, token: str) -> int:
    try:
        out = cast_call(rpc, token, "decimals()(uint8)")
    except Exception:
        # If decimals() does not exist or call fails, fall back to 18
        return 18
    if not out:
        return 18
    out = out.strip()
    # Some RPCs return a decimal string (e.g. "18"); others may return
    # hex (e.g. "0x12").  Cast call splits pretty output, so we only
    # need to inspect the first token.
    try:
        return int(out, 0) if out.startswith("0x") else int(out)
    except Exception:
        # Unknown format; default to 18
        return 18

def dec_to_fixed(d: Decimal) -> str:
    s = format(d, "f")           # fixed-point; no exponent
    s = s.rstrip("0").rstrip(".")
    return s or "0"

def int_commas(n: int) -> str:
    return f"{int(n):,}"

def dec_to_fixed_commas(d: Decimal) -> str:
    """Decimal → fixed-point string with thousands separators (no exponent)."""
    s = dec_to_fixed(d)
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        i, frac = s.split(".", 1)
    else:
        i, frac = s, ""
    i = f"{int(i):,}"
    return ("-" if neg else "") + i + (("." + frac) if frac else "")

# ------------- Pricing helpers -------------
def quote_torc_price_per_eth(rpc: str, router: str, torc: str, tokenB: str | None = None) -> tuple[Decimal, int, int]:
    """Return the TORC price per ETH for a given TORC pair.

    This helper inspects the reserves of the Uniswap V2 pair between
    ``torc`` and ``tokenB`` (WETH by default) and computes how many ETH are
    required to buy one TORC.  It returns a tuple of ``(price, reserve_torc,
    reserve_eth)``, where ``price`` is a high‑precision Decimal representing
    ETH per TORC and the reserves are raw integer values.  If the pair
    does not exist or has zero reserves the function raises a RuntimeError.

    Parameters
    ----------
    rpc: str
        RPC URL for the Ethereum network.
    router: str
        Address of the Uniswap V2 router.  Used to resolve WETH and
        factory addresses.
    torc: str
        Address of the TORC token.
    tokenB: str or None, optional
        Address of the counter token.  If None, the router's WETH address
        is used.

    Returns
    -------
    (Decimal, int, int)
        A tuple containing the TORC price in ETH as a Decimal and the
        raw reserve balances (TORC reserve and ETH reserve) of the pair.
    """
    # Resolve tokenB (default to WETH)
    other = tokenB or router_weth(rpc, router)
    # Look up the pair via the factory
    fct = router_factory(rpc, router)
    pair_addr = get_pair(rpc, fct, torc, other)
    if not pair_addr or pair_addr.lower() == "0x0000000000000000000000000000000000000000":
        raise RuntimeError("Pair does not exist; create it first with lp:create-pair")
    # Fetch reserves; use run() directly rather than cast_call() because cast_call
    # truncates the output to a single token.  The reserves call returns three
    # values separated by spaces (reserve0 reserve1 blockTimestamp).  We need
    # both reserves to compute the price.
    cmd = ["cast", "call", pair_addr, "getReserves()(uint112,uint112,uint32)", "--rpc-url", rpc]
    reserves_raw = run(cmd)
    if not reserves_raw:
        raise RuntimeError("Unable to fetch reserves; RPC returned empty result")
    parts = reserves_raw.split()
    if len(parts) < 2:
        raise RuntimeError(f"Unexpected getReserves output: {reserves_raw}")
    # Parse numeric values into big integers; supports hex and scientific notation
    reserve0 = parse_bigint(parts[0])
    reserve1 = parse_bigint(parts[2])
    # Determine token ordering
    t0 = pair_token0(rpc, pair_addr)
    # Fetch decimals for both tokens
    dec_torc = token_decimals(rpc, torc)
    dec_other = token_decimals(rpc, other)
    # Determine which reserve corresponds to TORC and which to ETH
    if t0.lower() == torc.lower():
        reserve_torc = reserve0
        reserve_eth = reserve1
    else:
        reserve_torc = reserve1
        reserve_eth = reserve0
    # Compute price in ETH per TORC: (reserve_eth / 10**dec_other) / (reserve_torc / 10**dec_torc)
    if reserve_torc == 0 or reserve_eth == 0:
        raise RuntimeError("Pair reserves are zero; cannot compute price")
    # Use Decimal for high precision
    price = (Decimal(reserve_eth) / (Decimal(10) ** dec_other)) / (Decimal(reserve_torc) / (Decimal(10) ** dec_torc))
    return price, reserve_torc, reserve_eth


def wei_str(x: int) -> str:
    """Return a string representation of an integer without scientific notation."""
    return str(int(x))


def big_lt(a: int, b: int) -> bool:
    """Return True if a < b after casting to int.  Handles big ints."""
    return int(a) < int(b)


def json_arg(s: str):
    """Parse a JSON argument or fail with a helpful message."""
    try:
        return json.loads(s)
    except json.JSONDecodeError as e:
        die(f"Invalid JSON: {e}")


# ------------- Router helpers -------------
def router_factory(rpc, router):
    return cast_call(rpc, router, "factory()(address)")


def router_weth(rpc, router):
    return cast_call(rpc, router, "WETH()(address)")


def get_pair(rpc, factory, tokenA, tokenB):
    return cast_call(rpc, factory, "getPair(address,address)(address)", tokenA, tokenB)


def pair_token0(rpc, pair):
    return cast_call(rpc, pair, "token0()(address)")


def pair_balance_of(rpc, pair, addr):
    return cast_call(rpc, pair, "balanceOf(address)(uint256)", addr)


def approve_exact_if_needed(rpc, pk, token, spender, amount_wei):
    """Ensure `spender` is approved for exactly `amount_wei` tokens.

    If the existing allowance is less than ``amount_wei`` the allowance
    is first set to zero and then set to ``amount_wei``.  This two step
    pattern avoids issues with some ERC‑20 tokens that require the
    allowance to be reset before changing it.
    """
    owner = cast_wallet_address(pk)
    allowance = cast_call(rpc, token, "allowance(address,address)(uint256)", owner, spender) or "0"
    try:
        current = int(allowance, 0) if allowance.startswith("0x") else int(allowance)
    except Exception:
        current = int(allowance.split()[0])
    if current < int(amount_wei):
        say(f"Approving {spender} for {amount_wei} on {token}")
        # reset to 0 then set exact (safe pattern)
        cast_send(rpc, pk, token, "approve(address,uint256)", spender, 0)
        cast_send(rpc, pk, token, "approve(address,uint256)", spender, amount_wei)


# ------------- Argument parsing -------------
parser = argparse.ArgumentParser(description="TORC Ops CLI (Python)")
parser.add_argument("--network", required=True, choices=["mainnet", "sepolia"])
parser.add_argument("--torc", required=True, help="TORC token address")

sub = parser.add_subparsers(dest="cmd", required=True)

# Admin/setup
p = sub.add_parser("setup:fee-split")
p.add_argument("addresses_json")
p.add_argument("bps_json")

p = sub.add_parser("setup:swap-fee"); p.add_argument("bps", type=int)
p = sub.add_parser("setup:threshold"); p.add_argument("wei", type=int)
p = sub.add_parser("setup:set-pair"); p.add_argument("pair")
p = sub.add_parser("setup:set-router"); p.add_argument("router")
p = sub.add_parser("setup:set-weth"); p.add_argument("weth")
p = sub.add_parser("setup:set-path"); p.add_argument("addresses_json")

# Pause/unpause
sub.add_parser("pause")
sub.add_parser("unpause")

# Fee exempt
p = sub.add_parser("fee-exempt:add"); p.add_argument("address")
p = sub.add_parser("fee-exempt:remove"); p.add_argument("address")

# Roles
p = sub.add_parser("roles:grant"); p.add_argument("role_name"); p.add_argument("account")
p = sub.add_parser("roles:revoke"); p.add_argument("role_name"); p.add_argument("account")
p = sub.add_parser("roles:renounce"); p.add_argument("role_name"); p.add_argument("account")
p = sub.add_parser("roles:check"); p.add_argument("role_name"); p.add_argument("account")

# TGE
p = sub.add_parser("tge:configure"); p.add_argument("recipients_json"); p.add_argument("whole_amounts_json")
sub.add_parser("tge:execute")

# Fees
p = sub.add_parser("fees:process")
p.add_argument("amountIn", nargs="?", default="0")
p.add_argument("amountOutMin", nargs="?", default="0")
p.add_argument("path_json", nargs="?", default="[]")
p.add_argument("deadline", nargs="?", default=None)

p = sub.add_parser("fees:distribute"); p.add_argument("amountWei")
p = sub.add_parser("fees:distribute-range")
p.add_argument("amountWei"); p.add_argument("start", type=int); p.add_argument("end", type=int)
sub.add_parser("fees:claim")

# LP
sub.add_parser("lp:router-info")
p = sub.add_parser("lp:get-pair"); p.add_argument("tokenB", nargs="?", default=None)
p = sub.add_parser("lp:create-pair"); p.add_argument("tokenB", nargs="?", default=None)

p = sub.add_parser("lp:add-eth")
p.add_argument("amountTokenDesired", help="whole TORC units (e.g. 1000 = 1000 TORC, not wei)")
p.add_argument("amountETH", help="whole ETH (e.g. 1.5)")
p.add_argument("to", nargs="?", default=None)
p.add_argument("amountTokenMin", nargs="?", default="0")
p.add_argument("amountETHMin", nargs="?", default="0")
p.add_argument("deadline", nargs="?", default=None)

p = sub.add_parser("lp:remove-eth")
p.add_argument("liquidity", help="'all', '<n>' LP (whole units), or '<n>wei'")
p.add_argument("to", nargs="?", default=None)
p.add_argument("amountTokenMinWei", nargs="?", default="0")
p.add_argument("amountETHMinWei", nargs="?", default="0")
p.add_argument("deadline", nargs="?", default=None)

p = sub.add_parser("lp:remove-eth-supporting")
p.add_argument("liquidity", help="'all', '<n>' LP (whole units), or '<n>wei'")
p.add_argument("to", nargs="?", default=None)
p.add_argument("amountTokenMinWei", nargs="?", default="0")
p.add_argument("amountETHMinWei", nargs="?", default="0")
p.add_argument("deadline", nargs="?", default=None)

p = sub.add_parser("lp:set-pair-on-torc"); p.add_argument("tokenB", nargs="?", default=None)

# Quote price
p = sub.add_parser("lp:quote")
p.add_argument("tokenB", nargs="?", default=None)

args = parser.parse_args()

# ------------- Resolve network/RPC/PK -------------
if args.network == "sepolia":
    RPC_URL = os.environ.get("SEPOLIA_RPC_URL") or die("Set SEPOLIA_RPC_URL in .env")
    PK = os.environ.get("TESTNET_DEPLOYER_PK") or die("Set TESTNET_DEPLOYER_PK in .env")
    ROUTER_ADDR = SEPOLIA_UNIV2_ROUTER
    DEFAULT_WETH = SEPOLIA_WETH
else:
    RPC_URL = os.environ.get("MAINNET_RPC_URL") or die("Set MAINNET_RPC_URL in .env")
    PK = os.environ.get("PROD_DEPLOYER_PK") or die("Set PROD_DEPLOYER_PK in .env")
    ROUTER_ADDR = MAINNET_UNIV2_ROUTER
    DEFAULT_WETH = MAINNET_WETH

TORC = args.torc

# ------------- Handlers -------------
cmd = args.cmd

# Admin / setup
if cmd == "setup:fee-split":
    recs = json_arg(args.addresses_json)
    bps = json_arg(args.bps_json)
    say(f"setFeeRecipients {recs} {bps}")
    cast_send(RPC_URL, PK, TORC, "setFeeRecipients(address[],uint256[])", json.dumps(recs), json.dumps(bps))

elif cmd == "setup:swap-fee":
    cast_send(RPC_URL, PK, TORC, "setSwapFee(uint256)", args.bps)

elif cmd == "setup:threshold":
    cast_send(RPC_URL, PK, TORC, "setFeeDistributionThreshold(uint256)", args.wei)

elif cmd == "setup:set-pair":
    cast_send(RPC_URL, PK, TORC, "setPairAddress(address)", args.pair)

elif cmd == "setup:set-router":
    cast_send(RPC_URL, PK, TORC, "setRouter(address)", args.router)

elif cmd == "setup:set-weth":
    cast_send(RPC_URL, PK, TORC, "setWETH(address)", args.weth)

elif cmd == "setup:set-path":
    path = json_arg(args.addresses_json)
    cast_send(RPC_URL, PK, TORC, "setDefaultSwapPath(address[])", json.dumps(path))

# Pause
elif cmd == "pause":
    cast_send(RPC_URL, PK, TORC, "pause()")

elif cmd == "unpause":
    cast_send(RPC_URL, PK, TORC, "unpause()")

# Fee exempt
elif cmd == "fee-exempt:add":
    cast_send(RPC_URL, PK, TORC, "setFeeExempt(address,bool)", args.address, True)

elif cmd == "fee-exempt:remove":
    cast_send(RPC_URL, PK, TORC, "setFeeExempt(address,bool)", args.address, False)

# Roles (hash role name via keccak in cast)
elif cmd in ("roles:grant", "roles:revoke", "roles:renounce", "roles:check"):
    role_hash = run(["cast", "keccak", args.role_name]).split()[0]
    if args.role_name == "DEFAULT_ADMIN_ROLE":
        role_hash = "0x" + "00" * 32 
    print(f"Role hash for {args.role_name}: {role_hash}")
    if cmd == "roles:grant":
        say(f"Grant {args.role_name} ({role_hash}) → {args.account}")
        cast_send(RPC_URL, PK, TORC, "grantRole(bytes32,address)", role_hash, args.account)
    elif cmd == "roles:revoke":
        say(f"Revoke {args.role_name} ({role_hash}) ← {args.account}")
        cast_send(RPC_URL, PK, TORC, "revokeRole(bytes32,address)", role_hash, args.account)
    elif cmd == "roles:renounce":
        say(f"Renounce {args.role_name} ({role_hash}) by {args.account}")
        cast_send(RPC_URL, PK, TORC, "renounceRole(bytes32,address)", role_hash, args.account)
    else:
        has = cast_call(RPC_URL, TORC, "hasRole(bytes32,address)(bool)", role_hash, args.account)
        print(f"{args.account} has {args.role_name}? {has}")

# TGE
elif cmd == "tge:configure":
    recs = json_arg(args.recipients_json)
    amts = json_arg(args.whole_amounts_json)
    cast_send(RPC_URL, PK, TORC, "configureTGE(address[],uint256[])", json.dumps(recs), json.dumps(amts))

elif cmd == "tge:execute":
    cast_send(RPC_URL, PK, TORC, "executeTGE()")

# Fees
elif cmd == "fees:process":
    amountIn = int(args.amountIn)
    amountOutMin = int(args.amountOutMin)
    path = json_arg(args.path_json)
    # deadline defaults to now+300 seconds if not provided
    deadline = int(args.deadline or (int(run(["date", "+%s"])) + 300))
    cast_send(RPC_URL, PK, TORC, "processFees(uint256,uint256,address[],uint256)", amountIn, amountOutMin, json.dumps(path), deadline)

elif cmd == "fees:distribute":
    cast_send(RPC_URL, PK, TORC, "distributeFees(uint256)", int(args.amountWei))

elif cmd == "fees:distribute-range":
    cast_send(RPC_URL, PK, TORC, "distributeFeesRange(uint256,uint256,uint256)", int(args.amountWei), args.start, args.end)

elif cmd == "fees:claim":
    cast_send(RPC_URL, PK, TORC, "claimFees()")

# LP / Router
elif cmd == "lp:router-info":
    fct = router_factory(RPC_URL, ROUTER_ADDR)
    w = router_weth(RPC_URL, ROUTER_ADDR)
    say(f"Router   : {ROUTER_ADDR}")
    say(f"Factory  : {fct}")
    say(f"WETH     : {w}")

elif cmd == "lp:get-pair":
    tokenB = args.tokenB or DEFAULT_WETH
    fct = router_factory(RPC_URL, ROUTER_ADDR)
    pair = get_pair(RPC_URL, fct, TORC, tokenB)
    say(f"getPair(TORC,{tokenB}) => {pair}")

elif cmd == "lp:create-pair":
    tokenB = args.tokenB or DEFAULT_WETH
    fct = router_factory(RPC_URL, ROUTER_ADDR)
    say(f"factory.createPair(TORC,{tokenB})")
    cast_send(RPC_URL, PK, fct, "createPair(address,address)", TORC, tokenB)
    pair = get_pair(RPC_URL, fct, TORC, tokenB)
    say(f"Pair created: {pair}")

elif cmd == "lp:add-eth":
    # Desired amounts in human units (whole TORC and ETH)
    human_torc = args.amountTokenDesired
    human_eth = args.amountETH
    # Receiver defaults to the deployer address if not specified
    to_addr = args.to or cast_wallet_address(PK)
    # Resolve token decimals on-chain.  Many ERC‑20 tokens do not use
    # 18 decimals; e.g. tokens with 6–8 decimals would cause an
    # incorrect 10^(18-decimals) scaling if we blindly applied
    # to_wei_18.  Query the decimals via the standard decimals()
    # function; fall back to 18 if the call fails.
    torc_decimals = token_decimals(RPC_URL, TORC)
    # Convert minimum amounts from human to smallest units.  When
    # specifying a plain number, it represents whole tokens (or ETH),
    # which are scaled by the token's decimals (or 18 for ETH).  If
    # suffixed with "wei" the raw integer is used as-is.
    amt_token_min = to_wei_with_decimals(str(args.amountTokenMin), torc_decimals)
    amt_eth_min = to_wei_with_decimals(str(args.amountETHMin), 18)
    # Deadline defaults to five minutes from now if not provided
    deadline = int(args.deadline or (int(run(["date", "+%s"])) + 300))

    # Convert desired amounts to smallest units using the token's
    # decimals.  This ensures a value like "20000" properly means
    # 20000 tokens (with correct decimals) rather than 20000 wei.
    token_desired_wei = to_wei_with_decimals(human_torc, torc_decimals)
    eth_wei = to_wei_with_decimals(human_eth, 18)

    # preflight balances
    deployer = cast_wallet_address(PK)
    sup_torc = cast_call(RPC_URL, TORC, "balanceOf(address)(uint256)", deployer)
    sup_eth = cast_balance(RPC_URL, deployer)
    sup_torc_i = int(sup_torc, 0) if sup_torc.startswith("0x") else int(sup_torc)
    sup_eth_i = int(sup_eth, 0) if sup_eth.startswith("0x") else int(sup_eth)

    # resolve WETH
    weth = router_weth(RPC_URL, ROUTER_ADDR)

    print("=== LP add preflight ===")
    print(f" Deployer           : {deployer}")
    print(f" Router             : {ROUTER_ADDR}")
    print(f" Token (TORC)       : {TORC}")
    print(f" TORC decimals      : {torc_decimals}")
    print(f" WETH               : {weth}")
    print(f" Receiver (to)      : {to_addr}")
    print(f" TORC desired       : {human_torc} TORC = {token_desired_wei} units (raw)")
    print(f" ETH desired        : {human_eth} ETH  = {eth_wei} wei")
    print(f" TORC balance       : {sup_torc_i} units (raw)")
    print(f" ETH  balance       : {sup_eth_i} wei")
    print(f" Min TORC (raw)     : {amt_token_min}")
    print(f" Min ETH  (wei)     : {amt_eth_min}")
    print(f" Deadline           : {deadline}")
    print("========================")

    if big_lt(sup_torc_i, token_desired_wei):
        die(f"ERROR: Insufficient TORC. Have {sup_torc_i} wei, need {token_desired_wei} wei.")
    if big_lt(sup_eth_i, eth_wei):
        die(f"ERROR: Insufficient ETH. Have {sup_eth_i} wei, need {eth_wei} wei.")

    say("Approving router for TORC (exact amount)…")
    approve_exact_if_needed(RPC_URL, PK, TORC, ROUTER_ADDR, token_desired_wei)

    say("Adding liquidity (TORC + ETH)…")
    # Single call that *includes* msg.value. No prior call without value.
    run([
        "cast", "send", ROUTER_ADDR,
        "addLiquidityETH(address,uint256,uint256,uint256,address,uint256)",
        TORC, wei_str(token_desired_wei), wei_str(amt_token_min), wei_str(amt_eth_min), to_addr, str(deadline),
        "--rpc-url", RPC_URL, "--private-key", PK, "--value", wei_str(eth_wei)
    ], capture=False)


elif cmd in ("lp:remove-eth", "lp:remove-eth-supporting"):
    to_addr = args.to or cast_wallet_address(PK)
    # Minimum token and ETH amounts.  These arguments are specified in
    # wei by the user, hence no conversion is performed here.  If a user
    # wants to specify whole units they can append 'wei' to the end of
    # the value or rely on to_wei_18 externally.
    amt_token_min = int(args.amountTokenMinWei)
    amt_eth_min = int(args.amountETHMinWei)
    deadline = int(args.deadline or (int(run(["date", "+%s"])) + 300))

    weth = router_weth(RPC_URL, ROUTER_ADDR)
    fct = router_factory(RPC_URL, ROUTER_ADDR)
    pair = get_pair(RPC_URL, fct, TORC, weth)
    if pair.lower() == "0x0000000000000000000000000000000000000000":
        die("No TORC/WETH pair exists. Create it first.")

    owner = cast_wallet_address(PK)
    lp_bal_raw = pair_balance_of(RPC_URL, pair, owner)
    lp_bal = int(lp_bal_raw, 0) if lp_bal_raw.startswith("0x") else int(lp_bal_raw)

    want = args.liquidity.strip()
    if want == "all":
        liquidity = lp_bal
        if liquidity == 0:
            die("You have zero LP tokens.")
    elif want.endswith("wei"):
        liquidity = int(want[:-3])
    else:
        # treat as whole LP amount (18d)
        liquidity = to_wei_18(want)

    if big_lt(lp_bal, liquidity):
        die(f"ERROR: Insufficient LP. Have {lp_bal} wei, need {liquidity} wei.")

    print(f"=== LP remove preflight ({'supporting FOT' if cmd.endswith('supporting') else 'standard'}) ===")
    print(f" Deployer           : {owner}")
    print(f" Router             : {ROUTER_ADDR}")
    print(f" Pair (LP token)    : {pair}")
    print(f" TORC               : {TORC}")
    print(f" WETH               : {weth}")
    print(f" LP balance (wei)   : {lp_bal}")
    print(f" Remove (wei)       : {liquidity}")
    print(f" Min TORC (wei)     : {amt_token_min}")
    print(f" Min ETH  (wei)     : {amt_eth_min}")
    print(f" Receiver (to)      : {to_addr}")
    print(f" Deadline           : {deadline}")
    print("============================================")

    say("Approving router for LP (pair) tokens…")
    approve_exact_if_needed(RPC_URL, PK, pair, ROUTER_ADDR, liquidity)

    if cmd == "lp:remove-eth":
        say("Removing liquidity via router.removeLiquidityETH(...)")
        cast_send(
            RPC_URL, PK, ROUTER_ADDR,
            "removeLiquidityETH(address,uint256,uint256,uint256,address,uint256)",
            TORC, liquidity, amt_token_min, amt_eth_min, to_addr, deadline
        )
    else:
        say("Removing liquidity via router.removeLiquidityETHSupportingFeeOnTransferTokens(...)")
        cast_send(
            RPC_URL, PK, ROUTER_ADDR,
            "removeLiquidityETHSupportingFeeOnTransferTokens(address,uint256,uint256,uint256,address,uint256)",
            TORC, liquidity, amt_token_min, amt_eth_min, to_addr, deadline
        )

elif cmd == "lp:set-pair-on-torc":
    tokenB = args.tokenB or DEFAULT_WETH
    fct = router_factory(RPC_URL, ROUTER_ADDR)
    pair = get_pair(RPC_URL, fct, TORC, tokenB)
    if pair.lower() == "0x0000000000000000000000000000000000000000":
        die("Pair does not exist. Use lp:create-pair first.")
    say(f"TORC.setPairAddress({pair})")
    cast_send(RPC_URL, PK, TORC, "setPairAddress(address)", pair)

elif cmd == "lp:quote":
    # Determine the counter token; default to WETH for the selected network
    tokenB = args.tokenB or DEFAULT_WETH
    try:
        price, reserve_torc, reserve_eth = quote_torc_price_per_eth(RPC_URL, ROUTER_ADDR, TORC, tokenB)
    except Exception as e:
        die(str(e))
    # Print out reserves and price information, remove torc decimals
    torc_decimals = token_decimals(RPC_URL, TORC)
    eth_decimals = 18 # WETH always has 18 decimals
    say(f"Pair reserves (human): TORC={int_commas(Decimal(reserve_torc) / (Decimal(10) ** torc_decimals))} ; ETH={int_commas(Decimal(reserve_eth) / (Decimal(10) ** eth_decimals))} ")
    # convert to human-readable format
    say(f"TORC price (ETH per TORC): {dec_to_fixed_commas(price)} ETH")

else:
    die(f"Unknown command: {cmd}")