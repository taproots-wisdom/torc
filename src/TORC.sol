// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title TORC ERC‑20 Token
 * @notice
 * - Fixed supply cap, burnable, EIP‑2612 permit, pausible, role-based ACL
 * - Swap fee ONLY on transfers involving the configured pair (e.g. Uniswap pool)
 * - Fees are collected in TORC during transfer (no external calls there)
 * - Conversion TORC->ETH happens via `processFees` (slippage/deadline/path controlled)
 * - ETH distribution uses push-when-possible; failed sends fall back to claimable pull
 * - Optional auto-accrual when a distribution threshold is reached (no auto-push in transfer path)
 * - Non-upgradeable; uses OpenZeppelin Contracts v5.x
 */
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal interface for Wrapped ETH (WETH) to enable deposit and withdrawal of ETH.
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @dev Minimal interface for Uniswap V2 style router to swap tokens for ETH.
/// Path must end with WETH when calling swapExactTokensForETH.
interface IUniswapV2Router02 {
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract TORC is ERC20, ERC20Permit, Pausable, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------
    //                               Roles
    // ------------------------------------------------------------------------
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant TGE_MANAGER_ROLE = keccak256("TGE_MANAGER_ROLE");
    bytes32 public constant FEE_EXEMPT_ROLE = keccak256("FEE_EXEMPT_ROLE");

    // ------------------------------------------------------------------------
    //                               Errors (gas‑saving)
    // ------------------------------------------------------------------------
    error ZeroAddress();
    error FeeTooHigh();
    error LengthMismatch();
    error BpsSumNot10000();
    error TransferWhilePaused();
    error AlreadyConfigured();
    error NotConfigured();
    error AlreadyExecuted();
    error ExceedsMaxSupply();
    error DuplicateRecipient();
    error InvalidRecipient();
    error InvalidAmount();
    error InvalidPath();
    error ETHTransferFailed();
    error AlreadyPaused();
    error NotPaused();

    // ------------------------------------------------------------------------
    //                          Token Supply Parameters
    // ------------------------------------------------------------------------
    /// @notice Maximum total supply of TORC tokens: 432 million with 18 decimals.
    uint256 public constant MAX_SUPPLY = 432_000_000 * 1e18;

    // ------------------------------------------------------------------------
    //                            Swap Fee Configuration
    // ------------------------------------------------------------------------
    /// @notice Swap fee in basis points (1 bp = 0.01%). Default is 3% (300 bps).
    uint256 public swapFeeBps;

    /// @notice Address of the liquidity pool (e.g., ETH/TORC Uniswap V2 pair).
    address public pairAddress;

    /// @notice ETH threshold at which accumulated fees are accrued for distribution.
    uint256 public feeDistributionThresholdWei;

    /// @notice Array of recipient addresses that receive fee distributions.
    address[] public feeRecipients;

    /// @notice Basis points for each recipient in `feeRecipients`. Sum must equal 10_000.
    uint256[] public feeRecipientBps;

    /// @notice Accumulated ETH awaiting distribution (undistributed, not yet assigned to recipients).
    uint256 public accumulatedFeeWei;

    /// @notice ETH that each recipient can claim (from failed push payouts or manual accrual).
    mapping(address => uint256) public pendingEth;

    /// @notice WETH & Router addresses (configurable).
    IWETH public weth;
    IUniswapV2Router02 public uniswapRouter;

    /// @notice Default swap path used in `processFees` when `path` arg is empty. Must start with TORC and end with WETH.
    address[] public defaultSwapPath;

    // ------------------------------------------------------------------------
    //                         Token Generation Event (TGE)
    // ------------------------------------------------------------------------
    bool public tgeConfigured;
    bool public tgeExecuted;

    /// @dev Mapping of addresses to TGE allocation amounts (in whole tokens, not wei).
    mapping(address => uint256) private tgeAllocations;
    /// @dev Internal list of TGE recipients for iteration during execution.
    address[] private tgeRecipientList;

    // ------------------------------------------------------------------------
    //                            Internal State Flags
    // ------------------------------------------------------------------------
    /// @dev True while performing router swap; prevents recursive feeing on internal transfers.
    bool private inSwap;
    /// @dev True while distributing; helps reduce reentrancy surface during push payouts.
    bool private inDistribution;

    // ------------------------------------------------------------------------
    //                               Events
    // ------------------------------------------------------------------------
    event FeeCollected(address indexed caller, uint256 amountETH);
    event FeeDistributed(address indexed recipient, uint256 amountETH);
    event FeeAccrued(address indexed recipient, uint256 amountETH); // when push fails, becomes claimable
    event FeesProcessed(uint256 amountInTorc, uint256 amountOutEth);

    event SwapFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeSplitUpdated(address[] recipients, uint256[] bps);
    event PairAddressUpdated(address indexed oldPair, address indexed newPair);
    event FeeThresholdUpdated(uint256 oldWei, uint256 newWei);
    event FeeExemptSet(address indexed account, bool exempt);

    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event WETHUpdated(address indexed oldWeth, address indexed newWeth);
    event DefaultSwapPathUpdated(address[] newPath);

    event TGEConfigured(address[] recipients, uint256[] wholeAmounts);
    event TGEExecuted();

    // ------------------------------------------------------------------------
    //                             Initialization
    // ------------------------------------------------------------------------
    constructor(address _weth, address _uniswapRouter) ERC20("TORC", "TORC") ERC20Permit("TORC") {
        if (_weth == address(0) || _uniswapRouter == address(0)) revert ZeroAddress();

        // Assign roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
        _grantRole(TGE_MANAGER_ROLE, msg.sender);
        _grantRole(FEE_EXEMPT_ROLE, msg.sender);

        // Defaults
        swapFeeBps = 300; // 3%
        feeDistributionThresholdWei = 0;
        accumulatedFeeWei = 0;

        // External addresses
        weth = IWETH(_weth);
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);

        // Approve router once for max (saves gas on each swap)
        _approve(address(this), _uniswapRouter, type(uint256).max);

        // Default path: [TORC, WETH]
        defaultSwapPath.push(address(this));
        defaultSwapPath.push(_weth);
        emit DefaultSwapPathUpdated(defaultSwapPath);
    }

    // ------------------------------------------------------------------------
    //                     External Configuration Functions
    // ------------------------------------------------------------------------
    function setPairAddress(address newPair) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newPair == address(0)) revert ZeroAddress();
        address old = pairAddress;
        pairAddress = newPair;
        emit PairAddressUpdated(old, newPair);
    }

    function setSwapFee(uint256 newFeeBps) external onlyRole(FEE_MANAGER_ROLE) {
        if (newFeeBps > 1000) revert FeeTooHigh(); // max 10%
        uint256 old = swapFeeBps;
        swapFeeBps = newFeeBps;
        emit SwapFeeUpdated(old, newFeeBps);
    }

    function setFeeDistributionThreshold(uint256 weiAmount) external onlyRole(FEE_MANAGER_ROLE) {
        uint256 old = feeDistributionThresholdWei;
        feeDistributionThresholdWei = weiAmount;
        emit FeeThresholdUpdated(old, weiAmount);
    }

    function setFeeRecipients(address[] calldata recipients, uint256[] calldata bps)
        external
        onlyRole(FEE_MANAGER_ROLE)
    {
        uint256 len = recipients.length;
        if (len == 0 || len != bps.length) revert LengthMismatch();

        uint256 total;
        // cache to memory (cheaper) and basic checks
        for (uint256 i; i < len;) {
            address r = recipients[i];
            if (r == address(0)) revert InvalidRecipient();
            // duplicate check (O(n^2) but len is expected small)
            for (uint256 j = i + 1; j < len;) {
                if (recipients[j] == r) revert DuplicateRecipient();
                unchecked {
                    ++j;
                }
            }
            total += bps[i];
            unchecked {
                ++i;
            }
        }
        if (total != 10_000) revert BpsSumNot10000();

        feeRecipients = recipients;
        feeRecipientBps = bps;
        emit FeeSplitUpdated(recipients, bps);
    }

    function setFeeExempt(address account, bool exempt) external onlyRole(FEE_MANAGER_ROLE) {
        if (exempt) {
            _grantRole(FEE_EXEMPT_ROLE, account);
        } else {
            _revokeRole(FEE_EXEMPT_ROLE, account);
        }
        emit FeeExemptSet(account, exempt);
    }

    /// @notice Update router; resets approvals accordingly.
    function setRouter(address newRouter) external onlyRole(FEE_MANAGER_ROLE) {
        if (newRouter == address(0)) revert ZeroAddress();
        address old = address(uniswapRouter);
        if (newRouter == old) return;

        // reset old allowance and set new max
        _approve(address(this), old, 0);
        _approve(address(this), newRouter, type(uint256).max);

        uniswapRouter = IUniswapV2Router02(newRouter);
        emit RouterUpdated(old, newRouter);
    }

    /// @notice Update WETH address; also validates default path end.
    function setWETH(address newWeth) external onlyRole(FEE_MANAGER_ROLE) {
        if (newWeth == address(0)) revert ZeroAddress();
        address old = address(weth);
        weth = IWETH(newWeth);
        // Enforce default path last hop = WETH
        if (defaultSwapPath.length >= 2) {
            defaultSwapPath[defaultSwapPath.length - 1] = newWeth;
            emit DefaultSwapPathUpdated(defaultSwapPath);
        }
        emit WETHUpdated(old, newWeth);
    }

    /// @notice Set default swap path. Must start with TORC and end with current WETH.
    function setDefaultSwapPath(address[] calldata path) external onlyRole(FEE_MANAGER_ROLE) {
        uint256 len = path.length;
        if (len < 2) revert InvalidPath();
        if (path[0] != address(this) || path[len - 1] != address(weth)) revert InvalidPath();

        delete defaultSwapPath;
        for (uint256 i; i < len;) {
            defaultSwapPath.push(path[i]);
            unchecked {
                ++i;
            }
        }
        emit DefaultSwapPathUpdated(defaultSwapPath);
    }

    // ------------------------------------------------------------------------
    //                        Token Generation Event (TGE)
    // ------------------------------------------------------------------------
    function configureTGE(address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyRole(TGE_MANAGER_ROLE)
    {
        if (tgeConfigured) revert AlreadyConfigured();
        uint256 len = recipients.length;
        if (len == 0 || len != amounts.length) revert LengthMismatch();

        uint256 totalAllocation;
        for (uint256 i; i < len;) {
            address r = recipients[i];
            uint256 amt = amounts[i];
            if (r == address(0)) revert InvalidRecipient();
            if (amt == 0) revert InvalidAmount();
            if (tgeAllocations[r] != 0) revert DuplicateRecipient();

            tgeAllocations[r] = amt;
            tgeRecipientList.push(r);
            totalAllocation += amt;
            unchecked {
                ++i;
            }
        }
        // Ensure total allocation does not exceed cap when converted to wei
        if (totalSupply() + (totalAllocation * (10 ** decimals())) > MAX_SUPPLY) revert ExceedsMaxSupply();

        tgeConfigured = true;
        emit TGEConfigured(recipients, amounts);
    }

    function executeTGE() external onlyRole(TGE_MANAGER_ROLE) whenNotPaused {
        if (!tgeConfigured) revert NotConfigured();
        if (tgeExecuted) revert AlreadyExecuted();
        tgeExecuted = true;

        uint8 dec = decimals();
        uint256 len = tgeRecipientList.length;
        for (uint256 i; i < len;) {
            address recipient = tgeRecipientList[i];
            uint256 amount = tgeAllocations[recipient];
            if (amount > 0) {
                uint256 mintAmount = amount * (10 ** dec);
                if (totalSupply() + mintAmount > MAX_SUPPLY) revert ExceedsMaxSupply();
                _mint(recipient, mintAmount);
                tgeAllocations[recipient] = 0;
            }
            unchecked {
                ++i;
            }
        }
        delete tgeRecipientList;
        emit TGEExecuted();
    }

    // ------------------------------------------------------------------------
    //                      Fee Swap & Distribution (decoupled)
    // ------------------------------------------------------------------------

    /**
     * @notice Convert collected TORC fees (held by this contract) to ETH via router.
     * @param amountIn     Amount of TORC to swap (0 => swap full contract balance)
     * @param amountOutMin Slippage protection (router param)
     * @param path         Swap path; if empty, uses defaultSwapPath (must end with WETH)
     * @param deadline     Router deadline (e.g., block.timestamp + 300)
     */
    function processFees(uint256 amountIn, uint256 amountOutMin, address[] calldata path, uint256 deadline)
        external
        nonReentrant
        onlyRole(FEE_MANAGER_ROLE)
    {
        // Determine path to use
        address[] memory p = path;
        if (p.length == 0) {
            p = defaultSwapPath;
        } else {
            if (p.length < 2 || p[0] != address(this) || p[p.length - 1] != address(weth)) revert InvalidPath();
        }

        uint256 bal = balanceOf(address(this));
        if (amountIn == 0 || amountIn > bal) amountIn = bal;
        if (amountIn == 0) return; // nothing to do

        // Record ETH before, then swap
        uint256 beforeEth = address(this).balance;
        inSwap = true;

        // We pre-approved router in constructor/setRouter, no need to re-approve every time
        uniswapRouter.swapExactTokensForETH(amountIn, amountOutMin, p, address(this), deadline);

        inSwap = false;
        uint256 received = address(this).balance - beforeEth;
        if (received > 0) {
            accumulatedFeeWei += received;
            emit FeeCollected(msg.sender, received);
            emit FeesProcessed(amountIn, received);

            // Optional auto-accrual if threshold is set and reached
            if (feeDistributionThresholdWei > 0 && accumulatedFeeWei >= feeDistributionThresholdWei) {
                _accrueDistribution(accumulatedFeeWei); // accrue entire available balance by default
            }
        }
    }

    /**
     * @notice Accrue (split) `amount` of accumulated ETH into recipients' balances and try to push.
     * Anyone can call this to progress distribution. If pushing fails for a recipient,
     * the amount becomes claimable via `claimFees()`.
     * @param amount Amount of ETH to accrue (0 => accrue up to available `accumulatedFeeWei`)
     */
    function distributeFees(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > accumulatedFeeWei) amount = accumulatedFeeWei;
        if (amount == 0) return;
        _accrueDistribution(amount);
    }

    /**
     * @notice Partial accrual to handle very large recipient lists in chunks.
     * Sums shares over [start, end) index range and updates state; does not push ETH.
     * @param amount Total amount to allocate proportionally across ALL recipients
     * @param start  Inclusive start index
     * @param end    Exclusive end index (must be <= feeRecipients.length)
     */
    function distributeFeesRange(uint256 amount, uint256 start, uint256 end) external nonReentrant {
        if (amount == 0 || amount > accumulatedFeeWei) amount = accumulatedFeeWei;
        if (amount == 0) return;

        uint256 len = feeRecipients.length;
        if (start >= end || end > len) revert LengthMismatch();

        // Accrue only a slice, proportionally (same as full loop but bounded)
        // Note: to keep math identical, we compute shares using the global BPS per index.
        uint256 totalAccounted;
        for (uint256 i = start; i < end;) {
            uint256 share = (amount * feeRecipientBps[i]) / 10_000;
            if (share > 0) {
                pendingEth[feeRecipients[i]] += share;
                totalAccounted += share;
                emit FeeAccrued(feeRecipients[i], share);
            }
            unchecked {
                ++i;
            }
        }

        if (totalAccounted > 0) {
            accumulatedFeeWei -= totalAccounted;
        }
    }

    /**
     * @notice Claim any ETH that is owed to the caller from failed push distributions or range accruals.
     */
    function claimFees() external nonReentrant {
        uint256 amt = pendingEth[msg.sender];
        if (amt == 0) revert InvalidAmount();
        pendingEth[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        if (!ok) revert ETHTransferFailed();
        emit FeeDistributed(msg.sender, amt);
    }

    // Internal: accrue + push-when-possible
    function _accrueDistribution(uint256 amount) internal {
        uint256 balance = address(this).balance;
        if (balance == 0 || feeRecipients.length == 0) return;

        uint256 distributionAmount = amount;
        if (distributionAmount > accumulatedFeeWei) distributionAmount = accumulatedFeeWei;
        if (distributionAmount > balance) distributionAmount = balance;
        if (distributionAmount == 0) return;

        uint256 totalAccounted;
        uint256 len = feeRecipients.length;

        // push payouts guarded; if push fails -> pending
        inDistribution = true;
        for (uint256 i; i < len;) {
            uint256 share = (distributionAmount * feeRecipientBps[i]) / 10_000;
            if (share > 0) {
                address r = feeRecipients[i];
                // try push
                (bool success,) = r.call{value: share}("");
                if (success) {
                    emit FeeDistributed(r, share);
                } else {
                    pendingEth[r] += share;
                    emit FeeAccrued(r, share);
                }
                totalAccounted += share;
            }
            unchecked {
                ++i;
            }
        }
        inDistribution = false;

        if (totalAccounted > 0) {
            accumulatedFeeWei -= totalAccounted; // remove what we allocated (pushed or accrued)
        }
    }

    // ------------------------------------------------------------------------
    //                           ERC20 Overrides
    // ------------------------------------------------------------------------
    /**
     * @dev Applies swap fee only when transferring to or from the configured pair.
     * No external calls here: we only collect TORC fees to this contract.
     * Transfers revert while paused (except mint/burn).
     */
    function _update(address from, address to, uint256 value) internal override {
        // Disallow transfers while paused (allow minting/burning via address(0))
        if (paused()) {
            if (from != address(0) && to != address(0)) revert TransferWhilePaused();
        }

        // Mint or burn: no fee logic
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        // Skip fee logic during internal router swaps
        if (inSwap || inDistribution) {
            super._update(from, to, value);
            return;
        }

        // Apply fee only for interactions with the pair
        address _pair = pairAddress;
        if (_pair != address(0) && (from == _pair || to == _pair)) {
            // Determine payer: if tokens come from pair, recipient pays; otherwise sender pays
            address payer = (from == _pair) ? to : from;
            if (!hasRole(FEE_EXEMPT_ROLE, payer) && swapFeeBps > 0) {
                uint256 feeAmount = (value * swapFeeBps) / 10_000;
                uint256 netAmount = value - feeAmount;

                // Collect fee to this contract (no swap here)
                super._update(from, address(this), feeAmount);
                // Deliver net amount
                super._update(from, to, netAmount);
                return;
            }
        }

        // Default behaviour: no fee
        super._update(from, to, value);
    }

    // ------------------------------------------------------------------------
    //                     Pausing and Emergency Functions
    // ------------------------------------------------------------------------
    function pause() external onlyRole(PAUSER_ROLE) {
        if (paused()) revert AlreadyPaused();
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        if (!paused()) revert NotPaused();
        _unpause();
    }

    /**
     * @notice Emergency withdrawal of ERC20 mistakenly sent to this contract.
     * @dev Admin power by design. Does not touch users' TORC balances.
     */
    function emergencyWithdrawERC20(address token, uint256 amount, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Emergency withdrawal of ETH mistakenly sent to this contract.
     * @dev Admin power by design. Use with care if you rely on pending/accumulated funds.
     */
    function emergencyWithdrawETH(uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    // ------------------------------------------------------------------------
    //                     ETH Receive Function
    // ------------------------------------------------------------------------
    receive() external payable {}
}
