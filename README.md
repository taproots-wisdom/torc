# TORC ERC-20 Token
[![Foundry CI](https://github.com/taproots-wisdom/torc/actions/workflows/foundry-ci.yml/badge.svg)](https://github.com/taproots-wisdom/torc/actions/workflows/foundry-ci.yml) [![License](https://img.shields.io/github/license/taproots-wisdom/torc.svg)](./LICENSE)

## Overview
**TORC** is a fixed-supply ERC-20 token with built-in fee collection, ETH distribution, EIP-2612 `permit` support, and role-based access control.  
It is designed for decentralized exchange (DEX) liquidity pools (e.g., Uniswap V2) where the protocol collects a fee on trades involving the configured pair, converts collected TORC fees to ETH, and distributes ETH to configured recipients.

The contract is **non-upgradeable**, uses [OpenZeppelin Contracts v5.x](https://github.com/OpenZeppelin/openzeppelin-contracts), and is heavily tested with both unit mocks and mainnet-fork integration tests.

---

## Key Features

### Tokenomics
- **Fixed supply cap:** 432 billion TORC (18 decimals).
- **Burnable:** Holders or approved spenders can burn tokens.
- **Token Generation Event (TGE):** One-time configuration & execution to mint allocations.
- **Non-mintable after TGE:** Supply can only decrease via burns.

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
  - `PAUSER_ROLE`: Pause/unpause transfers (except mint/burn).
  - `TGE_MANAGER_ROLE`: Configure and execute TGE.
  - `FEE_EXEMPT_ROLE`: Exempt address from paying swap fee.
- **Pausable:** Blocks transfers but still allows mint/burn and fee claims.
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
* Fee accrual and processing to ETH.
* Threshold, partial distribution, and paused pair transfers.
* Router allowance flips and pair address idempotence.

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
