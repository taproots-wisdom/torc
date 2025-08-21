// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/console2.sol";
import {TORC} from "../src/TORC.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactETHForTokens(
        uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external payable returns (uint[] memory amounts);
    function swapExactTokensForETH(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external returns (uint[] memory amounts);
    // Supporting fee-on-transfer tokens
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external payable;
}

/// @title TORC × UniswapV2 – Mainnet-fork integration tests
/// @notice Exercises real router/factory/WETH behavior against a fork to verify fee collection,
///         thresholds, pausability, router allowance management, and pair semantics.
/// @dev Requires `MAINNET_RPC_URL` in your environment. Forks at a fixed block for determinism.
contract Fork_UniswapV2_Test is Test {
    // --- Mainnet addresses ---
    address constant UNIV2_ROUTER  = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant MAINNET_WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IUniswapV2Router02 router = IUniswapV2Router02(UNIV2_ROUTER);
    IUniswapV2Factory  factory = IUniswapV2Factory(UNIV2_FACTORY);
    IWETH              weth    = IWETH(MAINNET_WETH);

    TORC token;
    address pair;

    // --- Actors ---
    address payable constant TREASURY = payable(address(0xBEEF));
    address payable constant ALICE    = payable(address(0xA11CE));
    address payable constant BOB      = payable(address(0xB0B));
    address payable constant CAROL    = payable(address(0xCAFE));
    address payable constant DAVE     = payable(address(0xD00D));
    address payable constant RECIP1   = payable(address(0xFEE1)); // 45%
    address payable constant RECIP2   = payable(address(0xFEE2)); // 45%
    address payable constant RECIP3   = payable(address(0xFEE3)); // 10%

    // ================================================================
    //                            Setup
    // ================================================================

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, 19_000_000);

        token = new TORC(MAINNET_WETH, UNIV2_ROUTER);

        // 100% fees → TREASURY
        address[] memory recs = new address[](1);
        uint256[] memory bps = new uint256[](1);
        recs[0] = TREASURY; bps[0] = 10_000;
        token.setFeeRecipients(recs, bps);

        // TGE → ALICE
        address[] memory tgeRec = new address[](1);
        uint256[] memory tgeAmt = new uint256[](1);
        tgeRec[0] = ALICE; tgeAmt[0] = 10_000_000;
        token.configureTGE(tgeRec, tgeAmt);
        token.executeTGE();

        // Pair
        pair = factory.getPair(address(token), MAINNET_WETH);
        if (pair == address(0)) {
            pair = factory.createPair(address(token), MAINNET_WETH);
        }
        token.setPairAddress(pair);

        vm.deal(ALICE, 1_000 ether);
        vm.deal(BOB,   200 ether);
    vm.deal(CAROL, 200 ether);
    vm.deal(DAVE,  200 ether);
    }

    // ================================================================
    //                         Internal helpers
    // ================================================================

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2); p[0] = a; p[1] = b;
    }
    function _exempt(address who) internal { token.setFeeExempt(who, true); }
    function _unexempt(address who) internal { token.setFeeExempt(who, false); }

    function _addLP(address provider, uint256 ethAmt, uint256 tokenAmt, address receiver) internal {
        vm.startPrank(provider);
        token.approve(UNIV2_ROUTER, type(uint256).max);
        router.addLiquidityETH{value: ethAmt}(
            address(token), tokenAmt, 0, 0, receiver, block.timestamp + 300
        );
        vm.stopPrank();
    }

    function _buy(address buyer, uint256 ethIn) internal {
        vm.startPrank(buyer);
        router.swapExactETHForTokens{value: ethIn}(
            0, _path(MAINNET_WETH, address(token)), buyer, block.timestamp + 300
        );
        vm.stopPrank();
    }

    /// @notice Seed LP from ALICE, then perform a buy from BOB.
    /// @dev Optionally exempts LP provider during add. Useful for tests that need immediate fee accrual.
    function _seedPoolAndBuy(
        uint256 lpEth, uint256 lpToken, uint256 buyEth, bool exemptProvider
    ) internal {
        if (exemptProvider) _exempt(ALICE);
        _addLP(ALICE, lpEth, lpToken, ALICE);
        if (exemptProvider) _unexempt(ALICE);
        _buy(BOB, buyEth);
    }

    // ================================================================
    //                             Tests
    // ================================================================

    function testFork_Univ2_AddLiquidity_Swap_CollectFees() public {
        _seedPoolAndBuy(50 ether, 2_000_000 * 1e18, 10 ether, true);
        uint256 torcFees = token.balanceOf(address(token));
        assertGt(torcFees, 0);

        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        uint256 accrued = token.accumulatedFeeWei();
        assertGt(accrued, 0);

        uint256 before = TREASURY.balance;
        token.distributeFees(accrued);
        assertGt(TREASURY.balance, before);
        assertEq(token.accumulatedFeeWei(), 0);
    }

    function testFork_Buy_FeeExemptBuyer_NoFee() public {
        _exempt(BOB);
        _seedPoolAndBuy(30 ether, 1_000_000 * 1e18, 5 ether, true);
        // No fee collected on exempt buyer
        assertEq(token.balanceOf(address(token)), 0);
    }

    function testFork_Buy_FeeCollected_WhenNotExempt() public {
        _seedPoolAndBuy(30 ether, 1_000_000 * 1e18, 5 ether, true);
        assertGt(token.balanceOf(address(token)), 0);
    }

    function testFork_ProcessFees_MinOutTooHigh_Reverts() public {
        _seedPoolAndBuy(40 ether, 1_200_000 * 1e18, 5 ether, true);
        assertGt(token.balanceOf(address(token)), 0);
        vm.expectRevert();
        token.processFees(0, type(uint256).max / 2, new address[](0), block.timestamp + 300);
    }

    function testFork_ProcessFees_ExpiredDeadline_Reverts() public {
        _seedPoolAndBuy(20 ether, 800_000 * 1e18, 2 ether, true);
        assertGt(token.balanceOf(address(token)), 0);
        vm.expectRevert();
        token.processFees(0, 0, new address[](0), block.timestamp - 1);
    }

    function testFork_Threshold_Accrues_NoAutoPush_PartialDistribute() public {
        token.setFeeDistributionThreshold(10 ether);
        _seedPoolAndBuy(40 ether, 1_200_000 * 1e18, 5 ether, true);

        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        uint256 accrued = token.accumulatedFeeWei();
        assertGt(accrued, 0);

        uint256 slice = accrued / 2;
        uint256 before = TREASURY.balance;
        token.distributeFees(slice);
        assertEq(token.accumulatedFeeWei(), accrued - slice);
        assertGt(TREASURY.balance, before);
    }

    function testFork_Paused_BlocksPairTransfers() public {
        _exempt(ALICE);
        _addLP(ALICE, 20 ether, 600_000 * 1e18, ALICE);
        vm.prank(ALICE);
        token.transfer(BOB, 100_000 * 1e18);
        _unexempt(ALICE);

        token.pause();
        vm.startPrank(BOB);
        token.approve(UNIV2_ROUTER, type(uint256).max);
        vm.expectRevert();
        router.swapExactTokensForETH(
            10_000 * 1e18, 0, _path(address(token), MAINNET_WETH), BOB, block.timestamp + 300
        );
        vm.stopPrank();
        token.unpause();
    }

    function testFork_SetRouter_AllowanceFlips() public {
        assertEq(token.allowance(address(token), UNIV2_ROUTER), type(uint256).max);
        token.setRouter(address(this));
        assertEq(token.allowance(address(token), UNIV2_ROUTER), 0);
        assertEq(token.allowance(address(token), address(this)), type(uint256).max);
        token.setRouter(UNIV2_ROUTER);
        assertEq(token.allowance(address(token), UNIV2_ROUTER), type(uint256).max);
        assertEq(token.allowance(address(token), address(this)), 0);
    }

    function testFork_FactoryPair_Exists_Idempotent() public {
        address existing = factory.getPair(address(token), MAINNET_WETH);
        assertTrue(existing != address(0));
        token.setPairAddress(existing);
        assertEq(existing, factory.getPair(address(token), MAINNET_WETH));
    }

    function testFork_CreatePoolAndQuote_64800000_TORC_75_ETH() public {
        // Deploy a fresh TORC so we can control TGE and avoid prior state
        TORC localToken = new TORC(MAINNET_WETH, UNIV2_ROUTER);

        // Configure TGE to mint 64.8 million TORC to ALICE and execute
        address[] memory recs = new address[](1);
        uint256[] memory amts = new uint256[](1);
        recs[0] = ALICE;
        amts[0] = 64_800_000; // whole tokens (18 decimals applied internally on execute)
        localToken.configureTGE(recs, amts);
        localToken.executeTGE();

        // Ensure the factory pair exists; create if needed
        address p = factory.getPair(address(localToken), MAINNET_WETH);
        if (p == address(0)) {
            p = factory.createPair(address(localToken), MAINNET_WETH);
        }
        assertTrue(p != address(0), "pair not created");

        // Add liquidity: 64.8M TORC and 75 ETH from ALICE
        vm.startPrank(ALICE);
        localToken.approve(UNIV2_ROUTER, type(uint256).max);
        router.addLiquidityETH{value: 75 ether}(
            address(localToken), 64_800_000 * 1e18, 0, 0, ALICE, block.timestamp + 300
        );
        vm.stopPrank();

        // Only now set the pair address on TORC to avoid fees during LP add
        localToken.setPairAddress(p);

        // Verify reserves by checking balances held by the pair
        uint256 reserveTORC = localToken.balanceOf(p);
        uint256 reserveWETH = weth.balanceOf(p);
        assertEq(reserveTORC, 64_800_000 * 1e18, "TORC reserve mismatch");
        assertEq(reserveWETH, 75 ether, "WETH reserve mismatch");

    // Quote price: TORC per 1 ETH = reserveTORC / reserveETH (both 18d → cancels)
    uint256 torcPerEthInt = reserveTORC / reserveWETH; // 64_800_000 / 75 = 864_000
    uint256 torcPerEthWad = (reserveTORC * 1e18) / reserveWETH; // 18-dec fixed point

        console2.log("Pair:", p);
        console2.log("Reserves TORC:", reserveTORC);
        console2.log("Reserves WETH:", reserveWETH);
        console2.log("TORC per ETH (int):", torcPerEthInt);
        console2.log("TORC per ETH (wad 1e18):", torcPerEthWad);
    }
    function testFork_CreateQuote_SetRecipients_SwapsAndDistribute_FeeSplit() public {
        // Deploy fresh TORC for isolation
        TORC localToken = new TORC(MAINNET_WETH, UNIV2_ROUTER);

        // TGE: 64.8M TORC to ALICE
        address[] memory tgeRec = new address[](1);
        uint256[] memory tgeAmt = new uint256[](1);
        tgeRec[0] = ALICE; tgeAmt[0] = 64_800_000;
        localToken.configureTGE(tgeRec, tgeAmt);
        localToken.executeTGE();

        // Ensure/create pair
        address p = factory.getPair(address(localToken), MAINNET_WETH);
        if (p == address(0)) {
            p = factory.createPair(address(localToken), MAINNET_WETH);
        }
        assertTrue(p != address(0), "pair not created");

        // Add liquidity: 64.8M TORC + 75 ETH
        vm.startPrank(ALICE);
        localToken.approve(UNIV2_ROUTER, type(uint256).max);
        router.addLiquidityETH{value: 75 ether}(
            address(localToken), 64_800_000 * 1e18, 0, 0, ALICE, block.timestamp + 300
        );
        vm.stopPrank();

        // Set pair to enable feeing on swaps
        localToken.setPairAddress(p);

        // Log price TORC per ETH
        uint256 reserveTORC = localToken.balanceOf(p);
        uint256 reserveWETH = weth.balanceOf(p);
        assertEq(reserveTORC, 64_800_000 * 1e18, "TORC reserve mismatch");
        assertEq(reserveWETH, 75 ether, "WETH reserve mismatch");
        uint256 torcPerEthInt = reserveTORC / reserveWETH; // 864,000
        uint256 torcPerEthWad = (reserveTORC * 1e18) / reserveWETH;
        console2.log("Pair:", p);
        console2.log("TORC per ETH (int):", torcPerEthInt);
        console2.log("TORC per ETH (wad 1e18):", torcPerEthWad);

        // Set fee recipients split 45/45/10
        address[] memory feeRec = new address[](3);
        uint256[] memory feeBps = new uint256[](3);
        feeRec[0] = RECIP1; feeBps[0] = 4_500;
        feeRec[1] = RECIP2; feeBps[1] = 4_500;
        feeRec[2] = RECIP3; feeBps[2] = 1_000;
        localToken.setFeeRecipients(feeRec, feeBps);

        // Exempt BOB from fees
        localToken.setFeeExempt(BOB, true);

        // 1) BOB buys 5 ETH TORC (no fee collected)
        uint256 feeTorcsBefore = localToken.balanceOf(address(localToken));
        vm.prank(BOB);
        router.swapExactETHForTokens{value: 5 ether}(0, _path(MAINNET_WETH, address(localToken)), BOB, block.timestamp + 300);
        uint256 feeTorcsAfter = localToken.balanceOf(address(localToken));
        assertEq(feeTorcsAfter, feeTorcsBefore, "Exempt buyer should not pay fee");

        // 2) CAROL buys 8 ETH TORC (fee collected)
        feeTorcsBefore = localToken.balanceOf(address(localToken));
        vm.prank(CAROL);
        router.swapExactETHForTokens{value: 8 ether}(0, _path(MAINNET_WETH, address(localToken)), CAROL, block.timestamp + 300);
        feeTorcsAfter = localToken.balanceOf(address(localToken));
        assertGt(feeTorcsAfter, feeTorcsBefore, "Non-exempt buy should collect fee");

        // 3) CAROL sells half TORC (fee collected)
        uint256 carolBal = localToken.balanceOf(CAROL);
        vm.startPrank(CAROL);
        localToken.approve(UNIV2_ROUTER, type(uint256).max);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            carolBal / 2, 0, _path(address(localToken), MAINNET_WETH), CAROL, block.timestamp + 300
        );
        vm.stopPrank();

        // Convert collected TORC fees to ETH
        localToken.processFees(0, 0, new address[](0), block.timestamp + 300);
        uint256 totalAccrued = localToken.accumulatedFeeWei();
        assertGt(totalAccrued, 0, "No ETH accrued");

        // Record balances then distribute
        uint256 r1Before = RECIP1.balance;
        uint256 r2Before = RECIP2.balance;
        uint256 r3Before = RECIP3.balance;
        localToken.distributeFees(0);

        uint256 exp1 = (totalAccrued * 4_500) / 10_000;
        uint256 exp2 = (totalAccrued * 4_500) / 10_000;
        uint256 exp3 = (totalAccrued * 1_000) / 10_000;

        assertEq(RECIP1.balance - r1Before, exp1, "RECIP1 share mismatch");
        assertEq(RECIP2.balance - r2Before, exp2, "RECIP2 share mismatch");
        assertEq(RECIP3.balance - r3Before, exp3, "RECIP3 share mismatch");

        uint256 leftover = localToken.accumulatedFeeWei();
        assertLe(leftover, (totalAccrued - (exp1 + exp2 + exp3)), "Leftover inconsistent");
    }
}
