# TORC ERC-20 Token
[![Foundry CI](https://github.com/taproots-wisdom/torc/actions/workflows/foundry-ci.yml/badge.svg)](https://github.com/taproots-wisdom/torc/actions/workflows/foundry-ci.yml) [![Codecov](https://codecov.io/gh/taproots-wisdom/torc/branch/main/graph/badge.svg)](https://codecov.io/gh/taproots-wisdom/torc) [![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0) [![Solidity](https://img.shields.io/badge/solidity-0.8.30-363636?logo=solidity&logoColor=white)](https://docs.soliditylang.org/en/v0.8.30/) [![Built with Foundry](https://img.shields.io/badge/built%20with-Foundry-fc8f00)](https://book.getfoundry.sh/) [![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.4-4E5EE4?logo=openzeppelin&logoColor=white)](https://github.com/OpenZeppelin/openzeppelin-contracts) ![EIP-2612](https://img.shields.io/badge/EIP--2612-permit-2ea44f) [![Sepolia Deploy](https://img.shields.io/badge/deploy-sepolia-6f3dc8?logo=ethereum&logoColor=white)](https://sepolia.etherscan.io/address/0x4f8fef11622837b5497ba67de26b41bb6a071059) [![Issues](https://img.shields.io/github/issues/taproots-wisdom/torc)](https://github.com/taproots-wisdom/torc/issues) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](.)


## Overview
**TORC** is a fixed-supply ERC-20 token with built-in fee collection, ETH distribution, EIP-2612 `permit` support, and role-based access control.  
It is designed for decentralized exchange (DEX) liquidity pools (e.g., Uniswap V2) where the protocol collects a fee on trades involving the configured pair, converts collected TORC fees to ETH, and distributes ETH to configured recipients.

The contract is **non-upgradeable**, uses [OpenZeppelin Contracts v5.x](https://github.com/OpenZeppelin/openzeppelin-contracts), and is heavily tested with both unit mocks and mainnet-fork integration tests.

---

## Key Features

### Tokenomics
- **Fixed supply cap:** 432 million TORC (18 decimals).
- **Token Generation Event (TGE):** One-time configuration & execution to mint allocations.
- **Non-mintable after TGE:** Supply is capped at 432 million TORC.

### ERC Standards
- **ERC-20** base implementation.
- **EIP-2612 `permit`:** Gasless approvals via signed messages.
- **EIP-712 domain separation** for signature replay protection.

### Fee Model
- **Swap fee only on DEX pair interactions:**
  - Applied when `from` or `to` is the configured liquidity pair.
  - Default: `300 bps` (3.00%).
- **Fee collection is in TORC:** No external calls in the transfer path.
- **Conversion to ETH via router:** `processFees` swaps TORC → ETH.
- **Distribution to recipients:**
  - Push when possible; failed sends accrue to `pendingEth` and can be claimed.
  - Configurable recipient list and basis points (must sum to 10_000).

### Administrative Controls
- **Role-based access control:**
  - `DEFAULT_ADMIN_ROLE`: Full control, emergency withdraws.
  - `FEE_MANAGER_ROLE`: Fee config, exemption lists, router/path updates.
  - `PAUSER_ROLE`: Pause/unpause transfers.
  - `TGE_MANAGER_ROLE`: Configure and execute TGE.
  - `FEE_EXEMPT_ROLE`: Exempt address from paying swap fee.
- **Pausable:** Blocks transfers.
- **Emergency withdraws:** Admin-only retrieval of stuck ETH/ERC-20.

### Miscellaneous
- **Distribution threshold:** Optional auto-accrual when collected ETH reaches a set amount.
- **Chunked distribution:** `distributeFeesRange` for large recipient sets.
- **Safe external calls:** Reentrancy-guarded fee processing and distributions.

---

## Limitations / Design Decisions

- **No upgradeability:** Contract is immutable once deployed.
- **Single fee tier:** All pair trades use the same `swapFeeBps`.
- **One pair address:** Only one liquidity pair is monitored for fee collection.
- **Manual fee processing:** Fees accrue in TORC until `processFees` is called.
- **Manual TGE execution:** TGE must be configured and explicitly executed.
- **Distribution push may fail:** Recipients with reverting `receive` functions must claim ETH manually.

---

## Deployment

### Prerequisites
- **Foundry**: [Install instructions](https://book.getfoundry.sh/getting-started/installation)
- **Node.js & npm**: For dependency installs (OpenZeppelin, forge-std, etc.).
- **.env**: Store sensitive config (e.g., RPC URL, deployer key).

Example `.env`:
```env
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
DEPLOYER_PRIVATE_KEY=0xabc123...
TOKEN_OWNER_PK=0xdef456... # Optional, for EIP-2612 tests
````

### Deploy Script

Deploy to your target network (example with Foundry script):

```sh
forge script script/DeployTORC.s.sol \
    --rpc-url $RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --broadcast
```

`DeployTORC.s.sol` should instantiate `TORC` with WETH and router addresses:

```solidity
new TORC(WETH_ADDRESS, UNISWAP_V2_ROUTER);
```

---

## Testing

### 1. Unit Tests (Mocked Router/WETH)

Run all local mock-based tests:

```sh
forge test -vvv
```

These tests (in `test/TORC.t.sol`) cover:

* Fee logic, exemptions, and pair absence.
* TGE guardrails.
* Pause/unpause behavior.
* Fee distribution, thresholds, and chunked payout.
* EIP-2612 `permit` flows, replay protection, nonce handling.
* Admin functions, path updates, and emergency withdraws.
* Reentrancy safety in distributions.

### 2. Mainnet-Fork Integration Tests

**Purpose:** Validate real Uniswap V2 router/factory/WETH behavior.

**Requirements:**

* `.env` must have `MAINNET_RPC_URL` pointing to a mainnet archive node.
* Fork block is fixed (`19_000_000`) for determinism.

Run fork tests:

```sh
forge test --match-path test/Fork_UniswapV2.t.sol -vv
```

Covers:

* Adding liquidity and buying/selling on a real Uniswap V2 pair.
* Creating a pool with 64.8M TORC and 75 ETH, verifying reserves, and logging price (TORC per ETH).
* Fee accrual and conversion via `processFees`, followed by distribution with a 45/45/10 recipient split.
* Fee-exempt vs fee-paying swap paths (recipient pays on buys; sender pays on sells).
* Using router “supporting fee-on-transfer” swap functions for sells to avoid UniswapV2: K reverts.
* Threshold, partial distribution, and paused pair transfers.
* Router allowance flips and pair address idempotence.

---

## Frontend test site (local)

MetaMask won’t inject on file:// pages; serve the demo over http(s).

Prereqs: Node.js (with npx) or Python 3.

Serve over HTTP

```powershell
# from repo root
cd frontend
# Option A: Python
python -m http.server 5173
# browse http://127.0.0.1:5173

# Option B: Node
npx http-server . -p 5173
# browse http://localhost:5173
```

Serve over HTTPS (optional)

```powershell
# generate a local cert (mkcert)
cd frontend
mkcert localhost 127.0.0.1
# serve with TLS via http-server
npx http-server . -p 8443 -S -C .\localhost+1.pem -K .\localhost+1-key.pem
# browse https://localhost:8443
```

Mobile testing without deploy (optional)

```powershell
# expose your local server
ngrok http 5173
# or
cloudflared tunnel --url http://localhost:5173
```

Notes
- Ensure the wallet network matches the configured router/token/pair addresses in `frontend/index.html`.
- Allow the MetaMask extension on the site (not “on click” only).
- The demo uses EIP‑1193 detection and only enables actions after account approval.

---

## File Structure

```
src/TORC.sol              # Token implementation
test/TORC.t.sol           # Unit tests with mocks
test/Fork_UniswapV2.t.sol # Mainnet-fork integration tests
test/mocks/               # Mock contracts (Router, WETH, ReentrantRecipient)
foundry.toml              # Foundry config
.env                      # Local environment variables (ignored by git)
```

---

## Example Workflow

1. **Deploy Token**
   `new TORC(WETH_ADDR, ROUTER_ADDR)`

2. **Configure TGE**
   `configureTGE([...recipients], [...amounts]); executeTGE();`

3. **Set Pair & Fee Recipients**
   `setPairAddress(pairAddr); setFeeRecipients([...], [...]);`

4. **Collect Fees**
   When users trade against the pair, fees accrue in TORC.

5. **Process & Distribute**
   Call `processFees()` to swap TORC → ETH, then `distributeFees()` or let threshold auto-accrue.

---

## Security Notes

* Only grant roles to trusted accounts.
* Use multisigs or timelocks for admin roles in production.
* Test `processFees` slippage and deadline parameters carefully.
* Pausing should be reserved for emergencies.

---

## License

[GNU General Public License v3.0](LICENSE)
