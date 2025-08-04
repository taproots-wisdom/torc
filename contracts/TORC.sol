// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title TORC ERC‑20 Token
 * @notice This contract implements the TORC token with a fixed supply cap, burnability,
 * permit functionality (EIP‑2612), pausability, role‑based access control, swap fee
 * management, fee accumulation and distribution in ETH, and a single‑execution
 * Token Generation Event (TGE). Only swaps executed through the configured
 * liquidity pair (initially ETH/TORC on Uniswap) incur a fee; regular transfers
 * between users are free of charge. Addresses marked with `FEE_EXEMPT_ROLE` are
 * exempt from swap fees. Swap fees are collected in TORC, converted to ETH via
 * a Uniswap V2‑style router and distributed to recipients once a threshold is met.
 *
 * @dev This contract is non‑upgradeable and uses OpenZeppelin Contracts v5.x. The
 * owner (DEFAULT_ADMIN_ROLE) can update fee parameters, add/remove fee‑exempt
 * addresses, set the liquidity pair address, and configure or execute the TGE.
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
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

/// @dev Minimal interface for Uniswap V2 style router to swap tokens for ETH. This interface
/// suffices for converting TORC tokens collected as fees into ETH so they can be
/// distributed according to the configured split.
interface IUniswapV2Router02 {
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract TORC is
    ERC20,
    ERC20Burnable,
    ERC20Permit,
    Pausable,
    AccessControl,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------
    //                               Roles
    // ------------------------------------------------------------------------
    /// @dev Role identifier for addresses allowed to pause and unpause the contract.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @dev Role identifier for addresses allowed to configure fee parameters and recipients.
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    /// @dev Role identifier for addresses allowed to configure and execute the TGE.
    bytes32 public constant TGE_MANAGER_ROLE = keccak256("TGE_MANAGER_ROLE");
    /// @dev Role identifier for addresses exempt from swap fees.
    bytes32 public constant FEE_EXEMPT_ROLE = keccak256("FEE_EXEMPT_ROLE");

    // ------------------------------------------------------------------------
    //                          Token Supply Parameters
    // ------------------------------------------------------------------------
    /// @notice Maximum total supply of TORC tokens: 432 billion with 18 decimals.
    uint256 public constant MAX_SUPPLY = 432_000_000_000 * 1e18;

    // ------------------------------------------------------------------------
    //                            Swap Fee Configuration
    // ------------------------------------------------------------------------
    /// @notice Swap fee in basis points (1 basis point = 0.01%). Default is 3% (300 bps).
    uint256 public swapFeeBps;

    /// @notice Address of the liquidity pool (initially the ETH/TORC pair). Transfers to
    /// or from this address are treated as swaps subject to the fee unless an
    /// exemption applies.
    address public pairAddress;

    /// @notice Threshold in wei upon which accumulated fees are distributed. Zero disables
    /// automatic distribution.
    uint256 public feeDistributionThresholdWei;

    /// @notice Array of recipient addresses that will receive fee distributions when the threshold is met.
    address[] public feeRecipients;
    /// @notice Basis points for each recipient in `feeRecipients`. Sum must equal 10_000 (100%).
    uint256[] public feeRecipientBps;

    /// @notice Accumulated ETH awaiting distribution. Fees collected in TORC are converted
    /// to ETH and accumulate until the threshold is reached.
    uint256 public accumulatedFeeWei;

    /// @notice Address of the WETH contract used to wrap and unwrap ETH when converting fees.
    IWETH public weth;

    /// @notice Address of the Uniswap V2 style router used to convert TORC tokens to ETH.
    IUniswapV2Router02 public uniswapRouter;

    // ------------------------------------------------------------------------
    //                         Token Generation Event (TGE)
    // ------------------------------------------------------------------------
    /// @notice Indicates whether TGE recipients and amounts have been configured.
    bool public tgeConfigured;
    /// @notice Indicates whether TGE has been executed.
    bool public tgeExecuted;

    /// @dev Mapping of addresses to TGE allocation amounts (in whole tokens, not wei). Used during configuration and execution.
    mapping(address => uint256) private tgeAllocations;
    /// @dev Internal list of TGE recipients for iteration during execution.
    address[] private tgeRecipientList;

    // ------------------------------------------------------------------------
    //                            Internal State Flags
    // ------------------------------------------------------------------------
    /// @dev Flag to indicate when the contract is in the middle of a swap and fee
    /// conversion. Used to prevent recursive fee collection on internal token
    /// transfers triggered by the Uniswap router during `swapExactTokensForETH`.
    bool private inSwap;

    // ------------------------------------------------------------------------
    //                               Events
    // ------------------------------------------------------------------------
    /// @notice Emitted when a swap fee is collected and converted to ETH.
    /// @param payer Address of the entity that paid the swap fee.
    /// @param amountETH Amount of ETH collected as fee.
    event FeeCollected(address indexed payer, uint256 amountETH);

    /// @notice Emitted when ETH is distributed to a fee recipient.
    /// @param recipient Address receiving the fee distribution.
    /// @param amountETH Amount of ETH distributed.
    event FeeDistributed(address indexed recipient, uint256 amountETH);

    /// @notice Emitted when the swap fee percentage is updated.
    /// @param oldFeeBps Previous fee in basis points.
    /// @param newFeeBps New fee in basis points.
    event SwapFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    /// @notice Emitted when the fee recipient split is updated.
    /// @param recipients Array of recipient addresses.
    /// @param bps Corresponding basis points for each recipient.
    event FeeSplitUpdated(address[] recipients, uint256[] bps);

    /// @notice Emitted when the swap pair address is updated.
    /// @param oldPair Previous pair address.
    /// @param newPair New pair address.
    event PairAddressUpdated(address indexed oldPair, address indexed newPair);

    // ------------------------------------------------------------------------
    //                             Initialization
    // ------------------------------------------------------------------------
    /**
     * @notice Contract constructor. Sets immutable token name and symbol, assigns
     * administrative roles to the deployer, configures fee parameters, records
     * external contract addresses, and initializes the token as paused=false. No
     * tokens are minted in the constructor; minting occurs via executeTGE.
     *
     * @param _weth Address of the Wrapped ETH contract.
     * @param _uniswapRouter Address of the Uniswap V2 style router for converting fees to ETH.
     */
    constructor(address _weth, address _uniswapRouter) ERC20("TORC", "TORC") ERC20Permit("TORC") {
        require(_weth != address(0), "WETH address cannot be zero");
        require(_uniswapRouter != address(0), "Router address cannot be zero");

        // Assign roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
        _grantRole(TGE_MANAGER_ROLE, msg.sender);

        // Set default fee parameters
        swapFeeBps = 300; // 3% fee
        feeDistributionThresholdWei = 0; // no auto distribution initially
        accumulatedFeeWei = 0;

        // External addresses
        weth = IWETH(_weth);
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
    }

    // ------------------------------------------------------------------------
    //                     External Configuration Functions
    // ------------------------------------------------------------------------
    /**
     * @notice Updates the address of the liquidity pair used to detect swaps. Transfers
     * involving this address are subject to the swap fee unless exempted. Only
     * callable by accounts with `DEFAULT_ADMIN_ROLE`.
     *
     * @param newPair Address of the new liquidity pair.
     */
    function setPairAddress(address newPair) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPair != address(0), "Pair address cannot be zero");
        address oldPair = pairAddress;
        pairAddress = newPair;
        emit PairAddressUpdated(oldPair, newPair);
    }

    /**
     * @notice Updates the basis points charged as swap fee. Only callable by
     * addresses holding the `FEE_MANAGER_ROLE`. The fee cannot exceed 10% (1000 bps).
     *
     * @param newFeeBps The new fee in basis points.
     */
    function setSwapFee(uint256 newFeeBps) external onlyRole(FEE_MANAGER_ROLE) {
        require(newFeeBps <= 1000, "Fee exceeds max of 10%");
        uint256 oldFee = swapFeeBps;
        swapFeeBps = newFeeBps;
        emit SwapFeeUpdated(oldFee, newFeeBps);
    }

    /**
     * @notice Updates the ETH threshold at which accumulated fees are distributed to
     * recipients. Only callable by addresses with the `FEE_MANAGER_ROLE`.
     *
     * @param weiAmount New threshold in wei. A value of zero disables automatic distribution.
     */
    function setFeeDistributionThreshold(uint256 weiAmount) external onlyRole(FEE_MANAGER_ROLE) {
        feeDistributionThresholdWei = weiAmount;
    }

    /**
     * @notice Configures the recipients and their respective shares of collected fees. Only
     * callable by addresses with the `FEE_MANAGER_ROLE`. The sum of `bps` must equal 10_000 (100%).
     *
     * @param recipients Array of addresses to receive fee distributions.
     * @param bps Array of basis points corresponding to each recipient.
     */
    function setFeeRecipients(address[] calldata recipients, uint256[] calldata bps) external onlyRole(FEE_MANAGER_ROLE) {
        require(recipients.length > 0, "Recipients required");
        require(recipients.length == bps.length, "Recipients and bps length mismatch");
        uint256 totalBps = 0;
        for (uint256 i = 0; i < bps.length; i++) {
            totalBps += bps[i];
        }
        require(totalBps == 10_000, "Total basis points must equal 10000");

        feeRecipients = recipients;
        feeRecipientBps = bps;
        emit FeeSplitUpdated(recipients, bps);
    }

    /**
     * @notice Marks or unmarks an address as exempt from paying swap fees. Only callable by
     * accounts with the `FEE_MANAGER_ROLE`.
     *
     * @param account Address to update exemption for.
     * @param exempt True to exempt the address from fees, false to remove exemption.
     */
    function setFeeExempt(address account, bool exempt) external onlyRole(FEE_MANAGER_ROLE) {
        if (exempt) {
            _grantRole(FEE_EXEMPT_ROLE, account);
        } else {
            _revokeRole(FEE_EXEMPT_ROLE, account);
        }
    }

    // ------------------------------------------------------------------------
    //                        Token Generation Event (TGE)
    // ------------------------------------------------------------------------
    /**
     * @notice Configures the recipients and amounts for the Token Generation Event. Can only
     * be called once, before execution, by addresses with the `TGE_MANAGER_ROLE`.
     *
     * @param recipients Array of addresses to receive initial token allocations (in whole tokens, not wei).
     * @param amounts Array of token amounts (without decimals) corresponding to each recipient.
     */
    function configureTGE(address[] calldata recipients, uint256[] calldata amounts) external onlyRole(TGE_MANAGER_ROLE) {
        require(!tgeConfigured, "TGE already configured");
        require(recipients.length > 0, "No recipients provided");
        require(recipients.length == amounts.length, "Recipients and amounts length mismatch");
        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Recipient cannot be zero address");
            require(amounts[i] > 0, "Allocation amount must be greater than zero");
            require(tgeAllocations[recipients[i]] == 0, "Duplicate recipient");
            tgeAllocations[recipients[i]] = amounts[i];
            tgeRecipientList.push(recipients[i]);
            totalAllocation += amounts[i];
        }
        // Ensure total allocation does not exceed cap when converted to wei
        require(totalSupply() + (totalAllocation * (10 ** decimals())) <= MAX_SUPPLY, "TGE allocation exceeds max supply");
        tgeConfigured = true;
    }

    /**
     * @notice Executes the Token Generation Event by minting tokens to configured recipients.
     * Can only be called once after configuration by addresses with the `TGE_MANAGER_ROLE`.
     */
    function executeTGE() external onlyRole(TGE_MANAGER_ROLE) whenNotPaused {
        require(tgeConfigured, "TGE not configured");
        require(!tgeExecuted, "TGE already executed");
        tgeExecuted = true;
        for (uint256 i = 0; i < tgeRecipientList.length; i++) {
            address recipient = tgeRecipientList[i];
            uint256 amount = tgeAllocations[recipient];
            if (amount > 0) {
                uint256 mintAmount = amount * (10 ** decimals());
                require(totalSupply() + mintAmount <= MAX_SUPPLY, "Mint would exceed max supply");
                _mint(recipient, mintAmount);
                tgeAllocations[recipient] = 0;
            }
        }
        delete tgeRecipientList;
    }

    // ------------------------------------------------------------------------
    //                          Fee and Distribution Logic
    // ------------------------------------------------------------------------
    /**
     * @dev Handles swap fee collection and conversion. Converts TORC fee tokens to ETH
     * via the configured Uniswap router, accumulates ETH, emits a `FeeCollected`
     * event and triggers distribution when threshold is met.
     *
     * @param payer Address responsible for paying the fee.
     * @param feeAmount Amount of TORC tokens taken as fee from the swap.
     */
    function _handleSwapFee(address payer, uint256 feeAmount) internal {
        if (feeAmount == 0) {
            return;
        }
        // Enter swap state to prevent fees on internal transfers
        inSwap = true;
        // Convert TORC tokens to ETH via the Uniswap router using path [TORC, WETH].
        // First approve the router to spend the fee tokens.
        SafeERC20.forceApprove(IERC20(address(this)), address(uniswapRouter), feeAmount);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = address(weth);
        uint256[] memory amounts = uniswapRouter.swapExactTokensForETH(
            feeAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
        // Exit swap state after conversion
        inSwap = false;
        uint256 ethReceived = amounts[amounts.length - 1];
        accumulatedFeeWei += ethReceived;
        emit FeeCollected(payer, ethReceived);
        // Distribute if threshold reached and auto distribution is enabled
        if (feeDistributionThresholdWei > 0 && accumulatedFeeWei >= feeDistributionThresholdWei) {
            _distributeFees();
        }
    }

    /**
     * @dev Distributes accumulated ETH fees to recipients according to their configured
     * basis points. Emits a `FeeDistributed` event for each recipient. Any remainder
     * due to rounding remains in `accumulatedFeeWei`.
     */
    function _distributeFees() internal {
        uint256 balance = address(this).balance;
        if (balance == 0 || feeRecipients.length == 0) {
            return;
        }
        // Determine how much to distribute (at most accumulatedFeeWei)
        uint256 distributionAmount = accumulatedFeeWei;
        if (distributionAmount > balance) {
            distributionAmount = balance;
        }
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < feeRecipients.length; i++) {
            uint256 share = (distributionAmount * feeRecipientBps[i]) / 10_000;
            if (share > 0) {
                (bool success, ) = feeRecipients[i].call{value: share}("");
                require(success, "ETH transfer failed");
                emit FeeDistributed(feeRecipients[i], share);
                totalDistributed += share;
            }
        }
        accumulatedFeeWei -= totalDistributed;
    }

    // ------------------------------------------------------------------------
    //                           ERC20 Overrides
    // ------------------------------------------------------------------------
    /**
     * @dev Overridden transfer function that applies swap fee when transferring to or
     * from the configured pair address. Regular transfers (i.e., not involving
     * the pair) proceed without fees. Exempt addresses are not charged.
     *
     * @param from Address sending tokens.
     * @param to Address receiving tokens.
     * @param amount Amount of tokens being transferred.
     */
    /**
     * @dev Overrides the internal balance update mechanism to apply swap fees when
     * transferring to or from the configured pair address. Regular transfers
     * between users proceed without fees. This function is called by the ERC20
     * implementation to adjust balances and emits the usual {Transfer} events.
     *
     * Requirements:
     * - The contract must not be paused (unless minting or burning).
     *
     * @param from Address tokens are transferred from. Zero address indicates minting.
     * @param to Address tokens are transferred to. Zero address indicates burning.
     * @param value Amount of tokens being transferred.
     */
    function _update(address from, address to, uint256 value) internal override {
        // Disallow transfers while paused (except minting/burning via address(0))
        if (paused()) {
            // Allow minting or burning when paused
            require(from == address(0) || to == address(0), "Pausable: token transfer while paused");
        }
        // Skip fee logic on minting or burning operations
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        // Skip fee logic during internal swaps triggered by the router
        if (inSwap) {
            super._update(from, to, value);
            return;
        }
        // Apply fee only when interacting with the pair address
        if (pairAddress != address(0) && (from == pairAddress || to == pairAddress)) {
            // Determine the payer of the fee: if tokens come from the pair, the recipient pays; otherwise the sender pays
            address payer = from == pairAddress ? to : from;
            if (!hasRole(FEE_EXEMPT_ROLE, payer) && swapFeeBps > 0) {
                uint256 feeAmount = (value * swapFeeBps) / 10_000;
                uint256 netAmount = value - feeAmount;
                // Transfer the fee to the contract
                super._update(from, address(this), feeAmount);
                // Transfer the net amount to the intended recipient
                super._update(from, to, netAmount);
                // Convert collected fee tokens to ETH and accumulate
                _handleSwapFee(payer, feeAmount);
                return;
            }
        }
        // Default behaviour: no fee
        super._update(from, to, value);
    }

    // ------------------------------------------------------------------------
    //                     Pausing and Emergency Functions
    // ------------------------------------------------------------------------
    /**
     * @notice Pauses the contract, preventing transfers, TGE execution, and swap fee
     * collection. Only callable by addresses holding the `PAUSER_ROLE`.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract, re-enabling transfers, TGE execution, and swap fee
     * collection. Only callable by addresses holding the `PAUSER_ROLE`.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency function to withdraw ERC‑20 tokens mistakenly sent to this contract.
     * Only callable by the `DEFAULT_ADMIN_ROLE`.
     *
     * @param token Address of the ERC‑20 token to withdraw.
     * @param amount Amount of tokens to withdraw.
     * @param to Recipient of the withdrawn tokens.
     */
    function emergencyWithdrawERC20(address token, uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(to != address(0), "Recipient cannot be zero address");
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Emergency function to withdraw ETH mistakenly sent to this contract.
     * Only callable by the `DEFAULT_ADMIN_ROLE`.
     *
     * @param amount Amount of ETH to withdraw.
     * @param to Recipient of the withdrawn ETH.
     */
    function emergencyWithdrawETH(uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(to != address(0), "Recipient cannot be zero address");
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    // ------------------------------------------------------------------------
    //                     ETH Receive Function
    // ------------------------------------------------------------------------
    /**
     * @notice Receive function to accept ETH. Required for the contract to
     * receive ETH from the Uniswap router when swapping TORC fees to ETH
     * and from WETH unwrap operations. Without this, such transfers would
     * revert.
     */
    receive() external payable {}
}
