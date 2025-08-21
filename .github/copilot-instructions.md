## Copilot instructions for the TORC repo

This repo implements a non-upgradeable ERC-20 token (TORC) with pair-aware swap fees, conversion of collected fees to ETH via Uniswap V2, and ETH distribution to recipients. Tests include both unit and mainnet-fork integration.

### Big picture and architecture
- Core contract: `src/TORC.sol` (OpenZeppelin v5.x base: ERC20, Burnable, Permit, Pausable, AccessControl, ReentrancyGuard).
- Fee model: fees are collected only when a transfer interacts with the configured liquidity pair (`pairAddress`). The fee payer is:
  - Buy (from pair → user): recipient pays.
  - Sell (user → pair): sender pays.
  Collected fees accrue in TORC in the token contract balance.
- Conversion and distribution:
  - `processFees(amountIn, amountOutMin, path, deadline)` swaps TORC → ETH via Uniswap V2 (default path `[TORC, WETH]`) and stores ETH as `accumulatedFeeWei`.
  - `distributeFees(amount)` or `distributeFeesRange` splits ETH among `feeRecipients` per `feeRecipientBps` (sum 10_000) and pushes via `call`; failed pushes accrue to `pendingEth`, claimable via `claimFees`.
- Roles: `DEFAULT_ADMIN_ROLE`, `FEE_MANAGER_ROLE`, `PAUSER_ROLE`, `TGE_MANAGER_ROLE`, `FEE_EXEMPT_ROLE` gate configuration and emergency functions.
- TGE: one-time `configureTGE([...recipients], [...wholeTokenAmounts])` then `executeTGE()` mints amounts × 10^decimals.

### Key files and directories
- `src/TORC.sol` – Token implementation and all fee/TGE/distribution logic.
- `test/TORC.t.sol` – Unit tests with mocks (fee logic, TGE, pause, distribution, permit, admin ops).
- `test/Fork_UniswapV2.t.sol` – Mainnet-fork tests against real Uniswap V2 router/factory/WETH.
- `foundry.toml` – Foundry configuration.

### Developer workflows
- Environment: Run all commands in a Linux bash shell (Ubuntu). Use bash syntax; do not emit PowerShell/CMD commands.
- Build/tests (unit): `forge test -vvv`
- Fork tests: require `MAINNET_RPC_URL` and use fixed block `19_000_000`.
  - Pattern: `vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 19_000_000);`
  - Run: `forge test --match-path test/Fork_UniswapV2.t.sol -vv`
- LP provisioning pattern in tests: add liquidity first, then call `setPairAddress(pair)` to avoid taking a fee during provisioning.

### Project conventions and patterns
- Basis points: all recipient BPS must sum to `10_000`; `swapFeeBps` max is `1000` (10%).
- Pair awareness: only one `pairAddress` is monitored for fees; transfers not involving the pair are fee-free.
- Safe paths: `setDefaultSwapPath` must start with `address(this)` and end with `WETH`.
- Internal guards: `inSwap` and `inDistribution` suppress feeing during router swaps and ETH pushes, respectively.
- TGE amounts are specified as whole tokens (decimals applied at execution), not wei.

### External dependencies and addresses
- Uniswap V2 Router (mainnet): `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`.
- WETH (mainnet): `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`.
- For non-mainnet networks, pass network-specific router/WETH addresses to the `TORC` constructor and adapt tests.

### Common task examples
- Configure fee recipients (45/45/10):
  ```solidity
  address[] memory rec = new address[](3);
  uint256[] memory bps = new uint256[](3);
  rec[0]=a; bps[0]=4500; rec[1]=b; bps[1]=4500; rec[2]=c; bps[2]=1000;
  token.setFeeRecipients(rec, bps);
  ```
- Exempt an address from fees:
  ```solidity
  token.setFeeExempt(someTrader, true);
  ```
- Process and distribute all fees:
  ```solidity
  token.processFees(0, 0, new address[](0), block.timestamp + 300); // swap all TORC->ETH
  token.distributeFees(0); // push per BPS
  ```

### Gotchas and test tips
- Set the pair address after adding initial liquidity to avoid fees during provisioning.
- Fee payer logic matters for assertions: buy (pair→user) charges recipient; sell (user→pair) charges sender.
- `processFees` expects a path beginning with TORC and ending in WETH; pass `[]` to use the default `[TORC, WETH]`.
- ETH push can fail; verify `pendingEth` for those recipients or call `claimFees()` in tests.
- Use `console2.log` for fork test diagnostics and `-vvv` verbosity for debugging.

### CI
- A Foundry CI workflow exists (see badge in `README.md`). Prefer adding fork tests only when `MAINNET_RPC_URL` is available in CI secrets.

### Open questions for maintainers
- License signals differ (SPDX headers show MIT while `README.md` links to GPLv3). Confirm the intended license to keep headers/docs consistent.
