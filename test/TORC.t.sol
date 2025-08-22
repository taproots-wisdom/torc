// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "lib/forge-std/src/Test.sol";
import {TORC} from "../src/TORC.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {ReentrantRecipient} from "./mocks/ReentrantRecipient.sol";
import {AlwaysRevertRecipient} from "./mocks/AlwaysRevertRecipient.sol";
import {TestableTORC} from "./mocks/TestableTORC.sol";
import {DecimalsMutateTORC} from "./mocks/DecimalsMutateTORC.sol";
import {PausableHarnessTORC} from "./mocks/PausableHarnessTORC.sol";

contract TORCTest is Test {
    // Allow this test contract to receive ETH (needed for MockWETH.withdraw)
    receive() external payable {}

    TORC token;
    MockRouter router;
    MockWETH weth;

    address payable constant ALICE = payable(address(uint160(uint256(keccak256("ALICE")))));
    address payable constant BOB = payable(address(uint160(uint256(keccak256("BOB")))));
    address payable constant CAROL = payable(address(uint160(uint256(keccak256("CAROL")))));
    address payable constant DAVE = payable(address(uint160(uint256(keccak256("DAVE")))));
    address payable constant ERIN = payable(address(uint160(uint256(keccak256("ERIN")))));

    address constant PAIR = address(uint160(uint256(keccak256("PAIR"))));

    function setUp() public {
        // deploy mocks
        weth = new MockWETH();
        router = new MockRouter();

        // deploy TORC
        token = new TORC(address(weth), address(router));

        // configure pair
        token.setPairAddress(PAIR);

        // TGE -> mint ALICE some tokens
        address[] memory recs = new address[](1);
        uint256[] memory amts = new uint256[](1);
        recs[0] = ALICE;
        amts[0] = 1_000_000; // whole tokens (1,000,000 * 1e18)
        token.configureTGE(recs, amts);
        token.executeTGE();

        // fund accounts / router
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
        vm.deal(CAROL, 10 ether);
        vm.deal(address(router), 100 ether); // router pays out swaps
    }

    // --- helpers ---

    function _makeFees(uint256 transferAmount) internal returns (uint256 feeTorc) {
        // ALICE -> PAIR, triggers fee collection (but no swapping in _update)
        vm.prank(ALICE);
        token.transfer(PAIR, transferAmount); // 3% fee goes to contract
        feeTorc = (transferAmount * 300) / 10_000; // default swapFeeBps=300
        assertEq(token.balanceOf(address(token)), feeTorc, "fee TORC not held");
    }

    // ---- EIP-2612 helpers (env key + signing) ----

    // Gracefully read TOKEN_OWNER_PK from .env, skipping tests if missing.
    function _tryGetPk() internal view returns (bool ok, uint256 pk) {
        try this.__readPk() returns (uint256 got) {
            return (true, got);
        } catch {
            return (false, 0);
        }
    }

    function __readPk() external view returns (uint256) {
        return vm.envUint("TOKEN_OWNER_PK");
    }

    // EIP-712/2612 constants for OZ ERC20Permit (name="TORC", version="1")
    bytes32 constant _EIP712DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _EIP712DOMAIN_TYPEHASH,
                keccak256(bytes(token.name())), // "TORC"
                keccak256(bytes("1")), // ERC20Permit version
                block.chainid,
                address(token)
            )
        );
    }

    function _signPermit(uint256 pk, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        uint256 nonce = token.nonces(owner);
        bytes32 structHash = keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        return vm.sign(pk, digest);
    }

    // Sign a permit with an explicit nonce (used for stale-nonce tests)
    function _signPermitWithNonce(
        uint256 pk,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint256 nonce
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        return vm.sign(pk, digest);
    }

    // 1) Reentrancy attempts via recipient fallback
    function test_ReentrancyFallback_PendingAndClaimWorks() public {
        // recipients: [reentrant, BOB], 60/40 split
        ReentrantRecipient reent = new ReentrantRecipient(address(token));
        address[] memory recs = new address[](2);
        uint256[] memory bps = new uint256[](2);
        recs[0] = address(reent);
        bps[0] = 6000;
        recs[1] = BOB;
        bps[1] = 4000;
        token.setFeeRecipients(recs, bps);

        // produce fees & process
        uint256 amount = 100_000 * 1e18; // 100k TORC
        uint256 feeTorc = _makeFees(amount); // 3k TORC fee
        assertEq(feeTorc, 3_000 * 1e18);
        // router RATE_DIV=1000 => 3000e18 / 1000 = 3 ETH
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        uint256 received = token.accumulatedFeeWei();
        assertEq(received, 3 ether, "unexpected ETH from router");

        // distribute (push). reentrant recipient reverts in receive(),
        // so his share becomes pending. BOB should get paid directly.
        uint256 bobBefore = BOB.balance;
        token.distributeFees(received);

        uint256 reentPending = token.pendingEth(address(reent));
        uint256 bobShare = (received * 4000) / 10_000;
        uint256 reentShare = (received * 6000) / 10_000;

        assertEq(BOB.balance, bobBefore + bobShare, "bob not paid");
        assertEq(reentPending, reentShare, "reentrant pending wrong");
        assertEq(token.accumulatedFeeWei(), 0, "accumulated not zeroed");

        // now the reentrant recipient claims
        uint256 reentBefore = address(reent).balance;
        vm.prank(address(reent));
        reent.claim();
        assertEq(address(reent).balance, reentBefore + reentShare, "reentrant not paid after claim");
        assertEq(token.pendingEth(address(reent)), 0, "pending not cleared");
    }

    // 2) Absent TORC/WETH pool (router revert) — transfers still succeed, fees accrue
    function test_TransfersSucceedWhenRouterReverts() public {
        // create fee via transfer touching pair
        uint256 amount = 50_000 * 1e18;
        uint256 feeTorc = _makeFees(amount);
        assertEq(token.balanceOf(address(token)), feeTorc, "fee not held");

        // now force router to revert when swapping
        router.setRevert(true);
        vm.expectRevert(); // any revert reason ok
        token.processFees(0, 0, new address[](0), block.timestamp + 300);

        // user transfers still OK (no external calls in _update)
        vm.prank(ALICE);
        token.transfer(BOB, 1_000 * 1e18); // user->user: no fee
        assertEq(token.balanceOf(BOB), 1_000 * 1e18, "transfer failed");
    }

    // 3) Distribution range chunking
    function test_DistributionRangeChunking() public {
        // recipients: 5 addrs with varied bps (sum 10000)
        address[] memory recs = new address[](5);
        uint256[] memory bps = new uint256[](5);
        recs[0] = ALICE;
        bps[0] = 2000;
        recs[1] = BOB;
        bps[1] = 3000;
        recs[2] = CAROL;
        bps[2] = 1000;
        recs[3] = DAVE;
        bps[3] = 1500;
        recs[4] = ERIN;
        bps[4] = 2500;
        token.setFeeRecipients(recs, bps);

        // generate large fees -> 30 ETH after swap
        uint256 amount = 1_000_000 * 1e18; // 1m TORC
        _makeFees(amount); // 30,000 TORC fee
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        assertEq(token.accumulatedFeeWei(), 30 ether, "want 30 ETH");

        // Range 1: allocate 2 ETH across [0..3)
        token.distributeFeesRange(2 ether, 0, 3);
        // check pending for first 3 recipients only
        assertEq(token.pendingEth(ALICE), (2 ether * 2000) / 10000);
        assertEq(token.pendingEth(BOB), (2 ether * 3000) / 10000);
        assertEq(token.pendingEth(CAROL), (2 ether * 1000) / 10000);
        assertEq(token.pendingEth(DAVE), 0);
        assertEq(token.pendingEth(ERIN), 0);

        // Range 2: allocate same 'amount' slice across [3..5)
        token.distributeFeesRange(2 ether, 3, 5);
        assertEq(token.pendingEth(DAVE), (2 ether * 1500) / 10000);
        assertEq(token.pendingEth(ERIN), (2 ether * 2500) / 10000);

        // accumulated decreased by exactly 2 ETH (sum ranges)
        assertEq(token.accumulatedFeeWei(), 28 ether);

        // claims succeed
        uint256 aliceBefore = ALICE.balance;
        uint256 bobBefore = BOB.balance;
        uint256 carBefore = CAROL.balance;
        uint256 daveBefore = DAVE.balance;
        uint256 erinBefore = ERIN.balance;

        vm.prank(ALICE);
        token.claimFees();
        vm.prank(BOB);
        token.claimFees();
        vm.prank(CAROL);
        token.claimFees();
        vm.prank(DAVE);
        token.claimFees();
        vm.prank(ERIN);
        token.claimFees();

        assertEq(ALICE.balance, aliceBefore + (2 ether * 2000) / 10000);
        assertEq(BOB.balance, bobBefore + (2 ether * 3000) / 10000);
        assertEq(CAROL.balance, carBefore + (2 ether * 1000) / 10000);
        assertEq(DAVE.balance, daveBefore + (2 ether * 1500) / 10000);
        assertEq(ERIN.balance, erinBefore + (2 ether * 2500) / 10000);
    }

    // 4) Threshold auto‑accrual after processFees
    function test_AutoAccrualOnThreshold() public {
        // recipients: 2 EOAs, 50/50
        address[] memory recs = new address[](2);
        uint256[] memory bps = new uint256[](2);
        recs[0] = BOB;
        bps[0] = 5000;
        recs[1] = CAROL;
        bps[1] = 5000;
        token.setFeeRecipients(recs, bps);

        // set threshold to 1 wei so any received triggers accrual+push
        token.setFeeDistributionThreshold(1);

        // generate ~3 ETH
        _makeFees(100_000 * 1e18);
        uint256 beforeBob = BOB.balance;
        uint256 beforeCarol = CAROL.balance;

        // auto-accrual triggers inside processFees
        token.processFees(0, 0, new address[](0), block.timestamp + 300);

        // accumulated should be fully allocated/pushed
        assertEq(token.accumulatedFeeWei(), 0, "should have auto-distributed");

        // both recipients got 1.5 ETH each
        assertEq(BOB.balance, beforeBob + 1.5 ether);
        assertEq(CAROL.balance, beforeCarol + 1.5 ether);
    }

    // 5) Admin updates to router/WETH/path (incl. allowance updates)
    function test_AdminUpdatesRouterWETHPath() public {
        // initial allowance to router == max
        assertEq(token.allowance(address(token), address(router)), type(uint256).max);

        // change router
        MockRouter router2 = new MockRouter();
        token.setRouter(address(router2));
        assertEq(token.allowance(address(token), address(router)), 0, "old router allowance not zeroed");
        assertEq(token.allowance(address(token), address(router2)), type(uint256).max, "new router allowance not set");

        // change WETH (and default path tail auto-updated)
        MockWETH weth2 = new MockWETH();
        token.setWETH(address(weth2));
        // default path should still be [TORC, WETH2]
        assertEq(token.defaultSwapPath(0), address(token));
        assertEq(token.defaultSwapPath(1), address(weth2));

        // set custom default path [TORC, DUMMY, WETH2]
        address dummy = address(uint160(uint256(keccak256("USDC"))));
        address[] memory path = new address[](3);
        path[0] = address(token);
        path[1] = dummy;
        path[2] = address(weth2);
        token.setDefaultSwapPath(path);
        assertEq(token.defaultSwapPath(0), address(token));
        assertEq(token.defaultSwapPath(1), dummy);
        assertEq(token.defaultSwapPath(2), address(weth2));

        // invalid path should revert
        address[] memory bad = new address[](2);
        bad[0] = dummy; // must start with TORC
        bad[1] = address(weth2);
        vm.expectRevert(TORC.InvalidPath.selector);
        token.setDefaultSwapPath(bad);
    }

    // -----------------------
    // Edge cases / regressions
    // -----------------------

    // Fee exempt payer should not be charged when selling to the pair.
    function test_FeeExempt_UserSell_NoFee() public {
        // Give ALICE exemption
        token.setFeeExempt(ALICE, true);

        // Transfer touching pair: no fee should be collected
        uint256 amount = 10_000 * 1e18;
        vm.prank(ALICE);
        token.transfer(PAIR, amount);
        assertEq(token.balanceOf(address(token)), 0, "fee should be 0 when exempt");

        // Remove exemption -> fee should be collected now
        token.setFeeExempt(ALICE, false);
        vm.prank(ALICE);
        token.transfer(PAIR, amount);
        uint256 expectedFee = (amount * 300) / 10_000;
        assertEq(token.balanceOf(address(token)), expectedFee, "fee should be collected");
    }

    // When no pair is configured, transfers must never take a fee.
    function test_NoPair_NoFeeOnTransfers() public {
        // Fresh token with no pair set
        TORC t = new TORC(address(weth), address(router));

        // Configure TGE -> mint ALICE
        address[] memory rec = new address[](1);
        uint256[] memory amt = new uint256[](1);
        rec[0] = ALICE;
        amt[0] = 10_000;
        t.configureTGE(rec, amt);
        t.executeTGE();

        // Transfer to any address (even our PAIR constant) should not take fee
        vm.prank(ALICE);
        t.transfer(PAIR, 1_000 * 1e18);
        assertEq(t.balanceOf(address(t)), 0, "no pair => no fee");
    }

    // Pausing blocks transfers and executeTGE is also blocked when paused.
    function test_Pause_BlocksTransfers_ExecuteTGEBlockedOnPause() public {
        // Pause
        token.pause();

        // Regular transfer should revert with custom error TransferWhilePaused
        vm.prank(ALICE);
        vm.expectRevert(TORC.TransferWhilePaused.selector);
        token.transfer(BOB, 1e18);

        // On a fresh token, executeTGE should revert while paused
        TORC t = new TORC(address(weth), address(router));
        address[] memory rec = new address[](1);
        uint256[] memory amt = new uint256[](1);
        rec[0] = ALICE;
        amt[0] = 1;
        t.configureTGE(rec, amt);
        t.pause();
        vm.expectRevert(); // whenNotPaused modifier revert
        t.executeTGE();

        // Unpause resumes transfers
        token.unpause();
        vm.prank(ALICE);
        token.transfer(BOB, 1e18);
    }

    // Slippage protection reverts swaps; state stays sane; subsequent swap works.
    function test_ProcessFees_SlippageReverts_ThenSucceeds() public {
        uint256 amount = 100_000 * 1e18; // expect 3k TORC fee -> 3 ETH if swapped
        _makeFees(amount);

        uint256 accBefore = token.accumulatedFeeWei();
        // Ask for >3 ETH to force slippage revert
        vm.expectRevert(); // mock router reverts with "slippage"
        token.processFees(0, 4 ether, new address[](0), block.timestamp + 300);
        assertEq(token.accumulatedFeeWei(), accBefore, "acc should not change on revert");

        // Now succeed with minOut=0
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        assertEq(token.accumulatedFeeWei(), accBefore + 3 ether, "should accrue 3 ETH");
    }

    // Invalid swap paths should revert.
    function test_ProcessFees_InvalidPath_Reverts() public {
        uint256 amount = 10_000 * 1e18;
        _makeFees(amount);

        // Path not starting with TORC
        address[] memory bad1 = new address[](2);
        bad1[0] = address(weth);
        bad1[1] = address(weth);
        vm.expectRevert(TORC.InvalidPath.selector);
        token.processFees(0, 0, bad1, block.timestamp + 300);

        // Path not ending with WETH
        address dummy = address(uint160(uint256(keccak256("USDC"))));
        address[] memory bad2 = new address[](2);
        bad2[0] = address(token);
        bad2[1] = dummy;
        vm.expectRevert(TORC.InvalidPath.selector);
        token.processFees(0, 0, bad2, block.timestamp + 300);
    }

    // setFeeRecipients guardrails.
    function test_SetFeeRecipients_RevertsOnBadInputs() public {
        // Length mismatch
        address[] memory recs = new address[](2);
        uint256[] memory bps = new uint256[](1);
        recs[0] = BOB;
        recs[1] = CAROL;
        bps[0] = 10_000;
        vm.expectRevert(TORC.LengthMismatch.selector);
        token.setFeeRecipients(recs, bps);

        // Zero address recipient
        address[] memory recs2 = new address[](1);
        uint256[] memory bps2 = new uint256[](1);
        recs2[0] = address(0);
        bps2[0] = 10_000;
        vm.expectRevert(TORC.InvalidRecipient.selector);
        token.setFeeRecipients(recs2, bps2);

        // Sum != 10000
        address[] memory recs3 = new address[](2);
        uint256[] memory bps3 = new uint256[](2);
        recs3[0] = BOB;
        bps3[0] = 4000;
        recs3[1] = CAROL;
        bps3[1] = 4000; // sum 8000
        vm.expectRevert(TORC.BpsSumNot10000.selector);
        token.setFeeRecipients(recs3, bps3);

        // Duplicate recipient
        address[] memory recs4 = new address[](2);
        uint256[] memory bps4 = new uint256[](2);
        recs4[0] = BOB;
        bps4[0] = 5000;
        recs4[1] = BOB;
        bps4[1] = 5000;
        vm.expectRevert(TORC.DuplicateRecipient.selector);
        token.setFeeRecipients(recs4, bps4);
    }

    // distributeFeesRange index checks.
    function test_DistributeFeesRange_BadIndices_Revert() public {
        // set minimal recipients
        address[] memory recs = new address[](2);
        uint256[] memory bps = new uint256[](2);
        recs[0] = BOB;
        bps[0] = 5000;
        recs[1] = CAROL;
        bps[1] = 5000;
        token.setFeeRecipients(recs, bps);

        // accrue some ETH
        _makeFees(100_000 * 1e18);
        token.processFees(0, 0, new address[](0), block.timestamp + 300);

        // start >= end
        vm.expectRevert(TORC.LengthMismatch.selector);
        token.distributeFeesRange(1 ether, 1, 1);

        // end > len
        vm.expectRevert(TORC.LengthMismatch.selector);
        token.distributeFeesRange(1 ether, 0, 3);
    }

    // Fee upper bound checks.
    function test_SwapFee_MaxAndTooHigh() public {
        token.setSwapFee(1000); // 10% OK
        vm.expectRevert(TORC.FeeTooHigh.selector);
        token.setSwapFee(1001);
    }

    // claimFees with zero pending should revert
    function test_ClaimFees_NoPending_Reverts() public {
        vm.expectRevert(TORC.InvalidAmount.selector);
        token.claimFees();
    }

    // distributeFees with zero accumulated should early return (no revert)
    function test_DistributeFees_Zero_NoOp() public {
        token.distributeFees(0);
        assertEq(token.accumulatedFeeWei(), 0);
    }

    // distributeFeesRange with zero accumulated should no-op silently (coverage)
    function test_DistributeFeesRange_Zero_NoOp() public {
        token.distributeFeesRange(0, 0, 0);
        assertEq(token.accumulatedFeeWei(), 0);
    }

    // processFees invalid path (length<2) using custom path arg
    function test_ProcessFees_PathTooShort_Reverts() public {
        _makeFees(10_000 * 1e18);
        address[] memory bad = new address[](1);
        bad[0] = address(token);
        vm.expectRevert(TORC.InvalidPath.selector);
        token.processFees(0, 0, bad, block.timestamp + 300);
    }

    // Exercise MockRouter.setRateDiv for coverage (non-zero change) and back
    function test_Router_SetRateDiv_AffectsProcess() public {
        _makeFees(200_000 * 1e18); // 6k TORC -> default 6 ETH at div=1000
        router.setRateDiv(2000); // now expect ~3 ETH
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        uint256 first = token.accumulatedFeeWei();
        assertApproxEqAbs(first, 3 ether, 1 wei);

        // Generate more fees and change rate again
        _makeFees(100_000 * 1e18); // 3k TORC
        router.setRateDiv(1500); // 3000/1500=2 ETH
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        uint256 total = token.accumulatedFeeWei();
        assertApproxEqAbs(total, first + 2 ether, 2 wei);
    }

    // Exercise MockWETH.withdraw path (not used by token directly) for coverage
    function test_MockWETH_Withdraw() public {
        // Deposit 1 ETH -> get 1 WETH
        vm.deal(address(this), address(this).balance + 1 ether);
        (bool ok,) = address(weth).call{value: 1 ether}("");
        require(ok, "deposit fail");
        uint256 balBefore = address(this).balance;
        weth.withdraw(0.4 ether);
        assertEq(weth.balanceOf(address(this)), 0.6 ether);
        assertEq(address(this).balance, balBefore + 0.4 ether);
    }

    // inDistribution flag branch: simulate by crafting recipients and forcing push
    function test_Distribution_InDistributionFlag() public {
        address[] memory recs = new address[](2);
        uint256[] memory bps = new uint256[](2);
        recs[0] = BOB;
        bps[0] = 7000;
        recs[1] = CAROL;
        bps[1] = 3000;
        token.setFeeRecipients(recs, bps);
        _makeFees(50_000 * 1e18);
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        uint256 acc = token.accumulatedFeeWei();
        uint256 bobBefore = BOB.balance;
        uint256 carolBefore = CAROL.balance;
        token.distributeFees(acc);
        // balances increased proportionally
        assertEq(BOB.balance - bobBefore, (acc * 7000) / 10000);
        assertEq(CAROL.balance - carolBefore, (acc * 3000) / 10000);
    }

    // Setting pair to zero address is forbidden.
    function test_SetPairAddress_ZeroReverts() public {
        vm.expectRevert(TORC.ZeroAddress.selector);
        token.setPairAddress(address(0));
    }

    // processFees no-ops when there is no TORC balance.
    function test_ProcessFees_ZeroBalance_NoOp() public {
        uint256 before = token.accumulatedFeeWei();
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        assertEq(token.accumulatedFeeWei(), before, "no change expected");
    }

    // No fee charged during internal router swap (guarded by inSwap).
    function test_InSwap_NoDoubleFeeDuringSwap() public {
        _makeFees(100_000 * 1e18); // contract holds 3k TORC
        uint256 beforeTorc = token.balanceOf(address(token));
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        // TORC fee balance should be fully spent; no extra TORC should be minted/collected
        assertEq(beforeTorc, 3_000 * 1e18);
        assertEq(token.balanceOf(address(token)), 0, "should not keep TORC after swap");
    }

    // Router/WETH/path: same router update should no-op; invalid default path reverts (already partly tested).
    function test_SetRouterSame_NoChange() public {
        address r0 = address(router);
        uint256 oldAllow = token.allowance(address(token), r0);
        token.setRouter(r0); // same
        assertEq(token.allowance(address(token), r0), oldAllow, "allowance should be unchanged");
    }

    // Emergency withdraws are admin-only and work.
    function test_EmergencyWithdraws() public {
        // Send 1 ETH to contract
        (bool ok,) = address(token).call{value: 1 ether}("");
        require(ok, "seed eth");

        // Non-admin cannot withdraw
        vm.prank(ALICE);
        vm.expectRevert(); // AccessControl check
        token.emergencyWithdrawETH(0.5 ether, BOB);

        // Admin can withdraw
        uint256 bobBefore = BOB.balance;
        token.emergencyWithdrawETH(0.5 ether, BOB);
        assertEq(BOB.balance, bobBefore + 0.5 ether);

        // ERC20 withdraw: send MockWETH to token
        // Mint WETH by depositing ETH
        vm.deal(address(this), address(this).balance + 1 ether);
        (ok,) = address(weth).call{value: 1 ether}(""); // deposit via receive()
        require(ok, "weth deposit");
        weth.transfer(address(token), 0.25 ether);
        uint256 adminBefore = weth.balanceOf(address(this));
        token.emergencyWithdrawERC20(address(weth), 0.25 ether, address(this));
        assertEq(weth.balanceOf(address(this)), adminBefore + 0.25 ether);
    }

    // TGE guardrails: already configured/executed/over-cap/not-configured, plus paused execution.
    function test_TGE_Guardrails() public {
        // Fresh token for clean TGE tests
        TORC t = new TORC(address(weth), address(router));

        // Execute without configuring -> NotConfigured
        vm.expectRevert(TORC.NotConfigured.selector);
        t.executeTGE();

        // Over-cap on configure
        address[] memory rec1 = new address[](1);
        uint256[] memory amt1 = new uint256[](1);
        rec1[0] = ALICE;
        amt1[0] = 432_000_000_001; // > max supply in whole tokens
        vm.expectRevert(TORC.ExceedsMaxSupply.selector);
        t.configureTGE(rec1, amt1);

        // Configure once OK
        address[] memory rec2 = new address[](1);
        uint256[] memory amt2 = new uint256[](1);
        rec2[0] = ALICE;
        amt2[0] = 10;
        t.configureTGE(rec2, amt2);

        // Configure again -> AlreadyConfigured
        vm.expectRevert(TORC.AlreadyConfigured.selector);
        t.configureTGE(rec2, amt2);

        // Pause blocks executeTGE
        t.pause();
        vm.expectRevert(); // whenNotPaused
        t.executeTGE();
        t.unpause();

        // Execute works once
        t.executeTGE();

        // Execute again -> AlreadyExecuted
        vm.expectRevert(TORC.AlreadyExecuted.selector);
        t.executeTGE();
    }

    // executeTGE over-cap check (trigger revert when minting due to decimals inflation after configure)
    function test_ExecuteTGE_OverCapDuringMint_Reverts() public {
        // Start with decimals=0 so large MAX_SUPPLY constant (18 decimals) easily accommodates allocation
        DecimalsMutateTORC h = new DecimalsMutateTORC(address(weth), address(router), 0);
        // Configure a trivial allocation (1) which passes cap check at decimals=0
        address[] memory recs = new address[](1);
        uint256[] memory amts = new uint256[](1);
        recs[0] = ALICE;
        amts[0] = 1; // totalAllocation * 10**0 = 1 << MAX_SUPPLY
        h.configureTGE(recs, amts);
        // Inflate decimals so mintAmount = 1 * 10**40 which will exceed MAX_SUPPLY (4.32e26)
        h.setDecimals(40);
        vm.expectRevert(TORC.ExceedsMaxSupply.selector);
        h.executeTGE();
    }

    // --- EIP-2612: permit -> approve -> transferFrom (using .env key) ---
    function test_Permit_ApproveAndTransferFrom_EnvKey() public {
        (bool ok, uint256 ownerPk) = _tryGetPk();
        if (!ok) {
            emit log("TOKEN_OWNER_PK not set; skipping");
            return;
        }
        address owner = vm.addr(ownerPk);

        // fund owner with TORC
        vm.prank(ALICE);
        token.transfer(owner, 1_000 ether);

        // sign permit for BOB
        uint256 value = 400 ether;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerPk, owner, BOB, value, deadline);

        // before
        assertEq(token.nonces(owner), 0);

        // permit -> allowance set & nonce increments
        token.permit(owner, BOB, value, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), value, "permit allowance mismatch");
        assertEq(token.nonces(owner), 1, "nonce not incremented");

        // replay should fail (nonce changed)
        vm.expectRevert();
        token.permit(owner, BOB, value, deadline, v, r, s);

        // BOB pulls some tokens
        uint256 pull = 150 ether;
        vm.prank(BOB);
        token.transferFrom(owner, BOB, pull);
        assertEq(token.balanceOf(BOB), pull);
        assertEq(token.allowance(owner, BOB), value - pull, "allowance not reduced");
    }

    // --- EIP-2612: expired deadline should revert ---
    function test_Permit_ExpiredDeadline_Reverts_EnvKey() public {
        (bool ok, uint256 ownerPk) = _tryGetPk();
        if (!ok) {
            emit log("TOKEN_OWNER_PK not set; skipping");
            return;
        }
        address owner = vm.addr(ownerPk);

        vm.prank(ALICE);
        token.transfer(owner, 100 ether);

        uint256 value = 50 ether;
        uint256 deadline = block.timestamp - 1; // already expired
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerPk, owner, BOB, value, deadline);

        vm.expectRevert(); // ERC2612ExpiredSignature / generic revert
        token.permit(owner, BOB, value, deadline, v, r, s);
    }

    // --- EIP-2612: wrong signer (signature doesn't match owner) ---
    function test_Permit_WrongSigner_Reverts_EnvKey() public {
        (bool ok, uint256 ownerPk) = _tryGetPk();
        if (!ok) {
            emit log("TOKEN_OWNER_PK not set; skipping");
            return;
        }
        address owner = vm.addr(ownerPk);

        vm.prank(ALICE);
        token.transfer(owner, 100 ether);

        // sign with a DIFFERENT key (ownerPk + 1)
        uint256 imposterPk = ownerPk + 1;
        uint256 value = 10 ether;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(imposterPk, owner, BOB, value, deadline);

        vm.expectRevert(); // ERC2612InvalidSigner / generic revert
        token.permit(owner, BOB, value, deadline, v, r, s);
    }

    // --- EIP-2612: multiple permits bump nonce; allowance is SET (not additive) ---
    function test_Permit_NonceBump_MultiPermits_EnvKey() public {
        (bool ok, uint256 ownerPk) = _tryGetPk();
        if (!ok) {
            emit log("TOKEN_OWNER_PK not set; skipping");
            return;
        }
        address owner = vm.addr(ownerPk);

        vm.prank(ALICE);
        token.transfer(owner, 1_000 ether);

        // 1st permit -> BOB: 100
        {
            uint256 deadline = block.timestamp + 1 days;
            (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerPk, owner, BOB, 100 ether, deadline);
            assertEq(token.nonces(owner), 0);
            token.permit(owner, BOB, 100 ether, deadline, v, r, s);
            assertEq(token.nonces(owner), 1);
            assertEq(token.allowance(owner, BOB), 100 ether);
        }

        // 2nd permit -> BOB: 250 (overwrites to 250, nonce=2)
        {
            uint256 deadline = block.timestamp + 1 days;
            (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerPk, owner, BOB, 250 ether, deadline);
            token.permit(owner, BOB, 250 ether, deadline, v, r, s);
            assertEq(token.nonces(owner), 2);
            assertEq(token.allowance(owner, BOB), 250 ether, "allowance must overwrite (not add)");
        }

        // Pull succeeds and reduces allowance
        vm.prank(BOB);
        token.transferFrom(owner, BOB, 60 ether);
        assertEq(token.allowance(owner, BOB), 190 ether);
    }

    // --- EIP-2612: global (per-owner) nonce blocks stale signatures across different spenders ---
    function test_Permit_StaleSignatureAcrossSpenders_Reverts_EnvKey() public {
        (bool ok, uint256 ownerPk) = _tryGetPk();
        if (!ok) {
            emit log("TOKEN_OWNER_PK not set; skipping");
            return;
        }
        address owner = vm.addr(ownerPk);

        vm.prank(ALICE);
        token.transfer(owner, 100 ether);

        // Use nonce 0 to permit BOB
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v0, bytes32 r0, bytes32 s0) = _signPermitWithNonce(ownerPk, owner, BOB, 10 ether, deadline, 0);
        token.permit(owner, BOB, 10 ether, deadline, v0, r0, s0);
        assertEq(token.nonces(owner), 1);

        // Now try to use a signature for CAROL that also uses NONCE 0 (stale) -> must revert
        (uint8 vBad, bytes32 rBad, bytes32 sBad) = _signPermitWithNonce(ownerPk, owner, CAROL, 10 ether, deadline, 0);
        vm.expectRevert(); // invalid signer / bad nonce
        token.permit(owner, CAROL, 10 ether, deadline, vBad, rBad, sBad);

        // Re-sign for CAROL with current nonce (1) -> succeeds
        (uint8 v1, bytes32 r1, bytes32 s1) = _signPermitWithNonce(ownerPk, owner, CAROL, 10 ether, deadline, 1);
        token.permit(owner, CAROL, 10 ether, deadline, v1, r1, s1);
        assertEq(token.nonces(owner), 2);
        assertEq(token.allowance(owner, CAROL), 10 ether);
    }

    // --- EIP-2612: chainId drift invalidates signatures until re-signed ---
    function test_Permit_ChainIdDrift_RevertsThenReSign_EnvKey() public {
        (bool ok, uint256 ownerPk) = _tryGetPk();
        if (!ok) {
            emit log("TOKEN_OWNER_PK not set; skipping");
            return;
        }
        address owner = vm.addr(ownerPk);

        vm.prank(ALICE);
        token.transfer(owner, 200 ether);

        uint256 deadline = block.timestamp + 1 days;

        // Sign under current chainId
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerPk, owner, BOB, 50 ether, deadline);

        // Change chainId -> signature domain no longer matches -> revert
        uint256 chainBefore = block.chainid;
        vm.chainId(chainBefore + 100); // drift
        vm.expectRevert();
        token.permit(owner, BOB, 50 ether, deadline, v, r, s);

        // Re-sign under new chainId -> success
        (uint8 v2, bytes32 r2, bytes32 s2) = _signPermit(ownerPk, owner, BOB, 50 ether, deadline);
        token.permit(owner, BOB, 50 ether, deadline, v2, r2, s2);
        assertEq(token.allowance(owner, BOB), 50 ether);
        assertEq(token.nonces(owner), 1);

        // restore chainId for isolation
        vm.chainId(chainBefore);
    }

    // --- EIP-2612: replay protection with stale signature after a later permit ---
    function test_Permit_ReplayAfterNewPermit_Reverts_EnvKey() public {
        (bool ok, uint256 ownerPk) = _tryGetPk();
        if (!ok) {
            emit log("TOKEN_OWNER_PK not set; skipping");
            return;
        }
        address owner = vm.addr(ownerPk);

        vm.prank(ALICE);
        token.transfer(owner, 300 ether);

        uint256 deadline = block.timestamp + 1 days;

        // First signature (nonce=0)
        (uint8 v0, bytes32 r0, bytes32 s0) = _signPermit(ownerPk, owner, BOB, 75 ether, deadline);
        token.permit(owner, BOB, 75 ether, deadline, v0, r0, s0);
        assertEq(token.nonces(owner), 1);

        // Second signature (nonce=1)
        (uint8 v1, bytes32 r1, bytes32 s1) = _signPermit(ownerPk, owner, BOB, 120 ether, deadline);
        token.permit(owner, BOB, 120 ether, deadline, v1, r1, s1);
        assertEq(token.nonces(owner), 2);
        assertEq(token.allowance(owner, BOB), 120 ether);

        // Try to replay the first signature again (uses nonce=0) -> revert
        vm.expectRevert();
        token.permit(owner, BOB, 75 ether, deadline, v0, r0, s0);
    }

    // --- Additional coverage tests for previously uncovered lines ---

    // Constructor should revert if either WETH or router is zero address.
    function test_Constructor_ZeroAddresses_Revert() public {
        vm.expectRevert(TORC.ZeroAddress.selector);
        new TORC(address(0), address(router));
        vm.expectRevert(TORC.ZeroAddress.selector);
        new TORC(address(weth), address(0));
    }

    // Explicit non-zero amountIn smaller than full balance path in processFees (no auto adjustment).
    function test_ProcessFees_PartialAmountIn() public {
        // generate fee TORC (3k)
        _makeFees(100_000 * 1e18);
        uint256 torcBal = token.balanceOf(address(token)); // 3000e18
        assertEq(torcBal, 3_000 * 1e18);
        // swap only half (1500e18)
        uint256 swapAmount = 1_500 * 1e18;
        token.processFees(swapAmount, 0, new address[](0), block.timestamp + 300);
        // leftover TORC should remain
        assertEq(token.balanceOf(address(token)), torcBal - swapAmount, "leftover TORC not retained");
        // accumulated ETH ~1.5 ETH (rateDiv=1000)
        assertApproxEqAbs(token.accumulatedFeeWei(), 1.5 ether, 1 wei);
    }

    // Setting swap fee to zero disables fee collection on pair transfers.
    function test_FeeDisabled_NoFeeTaken() public {
        token.setSwapFee(0);
        uint256 amount = 10_000 * 1e18;
        vm.prank(ALICE);
        token.transfer(PAIR, amount);
        assertEq(token.balanceOf(address(token)), 0, "fee should be zero when disabled");
    }

    // distributeFees with ETH and zero recipients triggers early return in _accrueDistribution.
    function test_DistributeFees_NoRecipients_EarlyReturn() public {
        // generate fees & swap to create accumulatedFeeWei > 0
        _makeFees(50_000 * 1e18); // 1500 TORC
        token.processFees(0, 0, new address[](0), block.timestamp + 300); // ~1.5 ETH
        uint256 accBefore = token.accumulatedFeeWei();
        // no recipients set -> distributeFees should not change state
        token.distributeFees(0);
        assertEq(token.accumulatedFeeWei(), accBefore, "acc should remain when no recipients");
    }

    // accumulatedFeeWei > actual ETH balance: only available ETH is distributed.
    function test_DistributeFees_PartialETHAvailable() public {
        // set recipients
        address[] memory recs = new address[](2);
        uint256[] memory bps = new uint256[](2);
        recs[0] = BOB;
        bps[0] = 6000;
        recs[1] = CAROL;
        bps[1] = 4000;
        token.setFeeRecipients(recs, bps);
        // produce ~3 ETH
        _makeFees(100_000 * 1e18);
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        uint256 accBefore = token.accumulatedFeeWei();
        assertApproxEqAbs(accBefore, 3 ether, 1 wei);
        // withdraw 1 ETH (admin) -> leaves ETH < accumulatedFeeWei
        token.emergencyWithdrawETH(1 ether, address(this));
        uint256 contractEth = address(token).balance;
        assertLt(contractEth, accBefore);
        // distribute: should only distribute contractEth
        uint256 bobBefore = BOB.balance;
        uint256 carolBefore = CAROL.balance;
        token.distributeFees(0);
        // distributed amount = contractEth; BOB share 60%, CAROL 40%
        assertEq(BOB.balance - bobBefore, (contractEth * 6000) / 10000);
        assertEq(CAROL.balance - carolBefore, (contractEth * 4000) / 10000);
        // accumulated decreased by distributed amount but still > 0 (undistributed remainder)
        assertEq(token.accumulatedFeeWei(), accBefore - contractEth);
    }

    // accumulatedFeeWei >0 but ETH balance drained to 0 -> early return on distribution (distributionAmount==0).
    function test_DistributeFees_NoETHButAccumulated() public {
        address[] memory recs = new address[](2);
        uint256[] memory bps = new uint256[](2);
        recs[0] = BOB;
        bps[0] = 5000;
        recs[1] = CAROL;
        bps[1] = 5000;
        token.setFeeRecipients(recs, bps);
        _makeFees(50_000 * 1e18); // 1500 TORC
        token.processFees(0, 0, new address[](0), block.timestamp + 300); // ~1.5 ETH
        uint256 accBefore = token.accumulatedFeeWei();
        // drain all ETH
        token.emergencyWithdrawETH(address(token).balance, address(this));
        assertEq(address(token).balance, 0);
        // distribute -> no change
        token.distributeFees(0);
        assertEq(token.accumulatedFeeWei(), accBefore, "acc unchanged when no ETH");
    }

    // Emergency withdraw ETH/ERC20 zero-address 'to' reverts.
    function test_EmergencyWithdrawETH_ZeroTo_Revert() public {
        vm.expectRevert(TORC.ZeroAddress.selector);
        token.emergencyWithdrawETH(0, address(0));
    }

    function test_EmergencyWithdrawERC20_ZeroTo_Revert() public {
        vm.expectRevert(TORC.ZeroAddress.selector);
        token.emergencyWithdrawERC20(address(weth), 0, address(0));
    }

    // --- Buy-side fee (pair -> user) ---
    function test_Buy_FeeCharged() public {
        // Seller ALICE sends to pair first to seed pair balance
        uint256 sellAmount = 1_000 * 1e18; // 1000 TORC
        vm.prank(ALICE);
        token.transfer(PAIR, sellAmount); // fee 3% => 30 TORC collected, 970 to pair
        assertEq(token.balanceOf(address(token)), (sellAmount * 300) / 10_000);
        uint256 pairBal = token.balanceOf(PAIR);
        assertEq(pairBal, 970 * 1e18);

        // Now pair sends tokens to BOB (buy). Fee should be charged (payer = BOB, but fee is skimmed from amount sent by pair so BOB receives less)
        vm.prank(PAIR);
        token.transfer(BOB, pairBal); // attempt to transfer full 970
        uint256 secondFee = (pairBal * 300) / 10_000; // 29.1 -> 29
        uint256 expectedNet = pairBal - secondFee;
        // Total fee tokens now 30 + 29 = 59
        assertEq(token.balanceOf(address(token)), ((sellAmount * 300) / 10_000) + secondFee);
        assertEq(token.balanceOf(BOB), expectedNet);
    }

    function test_Buy_FeeExemptRecipient_NoFee() public {
        // Seed pair with tokens via ALICE sell
        vm.prank(ALICE);
        token.transfer(PAIR, 1_000 * 1e18); // fee 30, pair 970
        // Exempt BOB
        token.setFeeExempt(BOB, true);
        uint256 feeSoFar = token.balanceOf(address(token));
        vm.prank(PAIR);
        token.transfer(BOB, 970 * 1e18); // should NOT take additional fee
        assertEq(token.balanceOf(address(token)), feeSoFar, "no extra fee when recipient exempt on buy");
        assertEq(token.balanceOf(BOB), 970 * 1e18);
    }

    // --- processFees: custom path branch (non-empty path provided) ---
    function test_ProcessFees_CustomPath_Used() public {
        _makeFees(50_000 * 1e18); // fee 1500 TORC -> expect 1.5 ETH
        address dummy = address(uint160(uint256(keccak256("DUMMY"))));
        address[] memory path = new address[](3);
        path[0] = address(token);
        path[1] = dummy; // ignored by mock router other than length check
        path[2] = address(weth);
        token.processFees(0, 0, path, block.timestamp + 300);
        assertApproxEqAbs(token.accumulatedFeeWei(), 1.5 ether, 1 wei);
    }

    // --- processFees: amountIn clamp (amountIn > balance) ---
    function test_ProcessFees_AmountClamp() public {
        _makeFees(100_000 * 1e18); // 3000 TORC
        uint256 torcBal = token.balanceOf(address(token));
        assertEq(torcBal, 3_000 * 1e18);
        // Request swap of more than balance -> should clamp to torcBal
        token.processFees(10_000_000 * 1e18, 0, new address[](0), block.timestamp + 300);
        // All fee TORC spent
        assertEq(token.balanceOf(address(token)), 0, "should have swapped full balance only");
        assertApproxEqAbs(token.accumulatedFeeWei(), (torcBal / 1000), 1 wei); // RATE_DIV=1000
    }

    // setRouter zero address guard (covers revert line)
    function test_SetRouter_ZeroAddress_Revert() public {
        vm.expectRevert(TORC.ZeroAddress.selector);
        token.setRouter(address(0));
    }

    // setWETH zero address guard (covers revert line in setWETH)
    function test_SetWETH_ZeroAddress_Revert() public {
        vm.expectRevert(TORC.ZeroAddress.selector);
        token.setWETH(address(0));
    }

    // configureTGE length mismatch / empty array guard
    function test_TGE_Configure_LengthMismatch_Empty() public {
        TORC t = new TORC(address(weth), address(router));
        address[] memory recs = new address[](0);
        uint256[] memory amts = new uint256[](0);
        vm.expectRevert(TORC.LengthMismatch.selector);
        t.configureTGE(recs, amts); // len==0 triggers revert
    }

    function test_TGE_Configure_LengthMismatch_DifferentLengths() public {
        TORC t = new TORC(address(weth), address(router));
        address[] memory recs = new address[](1);
        uint256[] memory amts = new uint256[](2);
        recs[0] = ALICE;
        amts[0] = 1;
        amts[1] = 2;
        vm.expectRevert(TORC.LengthMismatch.selector);
        t.configureTGE(recs, amts);
    }

    // configureTGE: zero address recipient -> InvalidRecipient
    function test_TGE_Configure_InvalidRecipient_ZeroAddress() public {
        TORC t = new TORC(address(weth), address(router));
        address[] memory recs = new address[](1);
        uint256[] memory amts = new uint256[](1);
        recs[0] = address(0);
        amts[0] = 1;
        vm.expectRevert(TORC.InvalidRecipient.selector);
        t.configureTGE(recs, amts);
    }

    // configureTGE: zero amount allocation -> InvalidAmount
    function test_TGE_Configure_InvalidAmount_ZeroAllocation() public {
        TORC t = new TORC(address(weth), address(router));
        address[] memory recs = new address[](1);
        uint256[] memory amts = new uint256[](1);
        recs[0] = ALICE;
        amts[0] = 0; // zero amount
        vm.expectRevert(TORC.InvalidAmount.selector);
        t.configureTGE(recs, amts);
    }

    // configureTGE: duplicate recipient within single call -> DuplicateRecipient
    function test_TGE_Configure_DuplicateRecipient_InCall() public {
        TORC t = new TORC(address(weth), address(router));
        address[] memory recs = new address[](2);
        uint256[] memory amts = new uint256[](2);
        recs[0] = ALICE;
        recs[1] = ALICE; // duplicate
        amts[0] = 5;
        amts[1] = 10;
        vm.expectRevert(TORC.DuplicateRecipient.selector);
        t.configureTGE(recs, amts);
    }

    // claimFees push failure path -> ETHTransferFailed (line 444)
    function test_ClaimFees_RevertOnFailedSend() public {
        // Deploy fresh token & configure fee recipients where one recipient will revert on receive
        TORC t = new TORC(address(weth), address(router));
        // Create a recipient that reverts on receive
        AlwaysRevertRecipient bad = new AlwaysRevertRecipient(address(t));
        address[] memory recs = new address[](2);
        uint256[] memory bps = new uint256[](2);
        recs[0] = address(bad);
        bps[0] = 7000;
        recs[1] = BOB;
        bps[1] = 3000;
        t.setFeeRecipients(recs, bps);

        // Configure & execute TGE so ALICE has tokens to generate fees
        address[] memory trec = new address[](1);
        uint256[] memory tamt = new uint256[](1);
        trec[0] = ALICE;
        tamt[0] = 100_000; // whole tokens
        t.configureTGE(trec, tamt);
        t.executeTGE();
        // Set pair (needed for fees) and fund ALICE ETH
        t.setPairAddress(PAIR);
        vm.deal(ALICE, 5 ether);
        vm.deal(address(router), 50 ether);

        // Generate fees by selling to pair
        vm.prank(ALICE);
        t.transfer(PAIR, 50_000 * 1e18); // 3% fee -> 1500e18 TORC in contract
        // Swap fees to ETH
        t.processFees(0, 0, new address[](0), block.timestamp + 300);
        uint256 acc = t.accumulatedFeeWei();
        assertGt(acc, 0);

        // Distribute fully so pending/attempted push occurs. Bad recipient push will fail => pending
        t.distributeFees(acc);
        // Its pending balance should now be non-zero (pushed failed), BOB got paid
        uint256 pendingBefore = t.pendingEth(address(bad));
        assertGt(pendingBefore, 0, "expected pending for bad recipient");

        // Now impersonate bad contract and attempt claim -> receive() will revert, claimFees should revert ETHTransferFailed
        vm.prank(address(bad));
        vm.expectRevert(TORC.ETHTransferFailed.selector);
        bad.claim();
    }

    // _accrueDistribution clamp test: amount > accumulatedFeeWei -> clamps to accumulated (line 454)
    function test_AccrueDistribution_ClampToAccumulated() public {
        // Use harness exposing internal function
        TestableTORC t = new TestableTORC(address(weth), address(router));
        // Recipients
        address[] memory recs = new address[](2);
        uint256[] memory bps = new uint256[](2);
        recs[0] = BOB;
        bps[0] = 6000;
        recs[1] = CAROL;
        bps[1] = 4000;
        t.setFeeRecipients(recs, bps);

        // TGE allocate to ALICE
        address[] memory trec = new address[](1);
        uint256[] memory tamt = new uint256[](1);
        trec[0] = ALICE;
        tamt[0] = 100_000;
        t.configureTGE(trec, tamt);
        t.executeTGE();
        t.setPairAddress(PAIR);
        vm.deal(ALICE, 5 ether);
        vm.deal(address(router), 50 ether);

        // Generate fee tokens (3% of 50k)
        vm.prank(ALICE);
        t.transfer(PAIR, 50_000 * 1e18); // fee 1500e18
        // Swap all fee TORC -> ETH
        t.processFees(0, 0, new address[](0), block.timestamp + 300);
        uint256 acc = t.accumulatedFeeWei();
        assertGt(acc, 0);

        // Call internal accrue with oversized amount (10x) to trigger clamp to accumulatedFeeWei
        uint256 bobBefore = BOB.balance;
        uint256 carolBefore = CAROL.balance;
        t.callAccrueDistribution(acc * 10);
        // After distribution accumulated should be zero
        assertEq(t.accumulatedFeeWei(), 0, "acc not fully consumed");
        uint256 distributed = (BOB.balance - bobBefore) + (CAROL.balance - carolBefore);
        assertApproxEqAbs(distributed, acc, 1 wei);
    }

    // Explicit coverage for pause() line (_pause() internal call) without additional logic
    function test_Pause_StateFlip() public {
        assertFalse(token.paused(), "should start unpaused");
        token.pause();
        assertTrue(token.paused(), "pause() did not set state");
    }

    // Explicit coverage for unpause() line (_unpause() internal call)
    function test_Unpause_StateFlip() public {
        token.pause();
        assertTrue(token.paused(), "expected paused");
        token.unpause();
        assertFalse(token.paused(), "expected unpaused after unpause()");
        // sanity: transfer works again
        vm.prank(ALICE);
        token.transfer(BOB, 1e18);
    }

    // Additional: calling pause() while already paused should revert (covers require branch in _pause())
    function test_Pause_DoublePause_Reverts() public {
        assertFalse(token.paused());
        token.pause();
        assertTrue(token.paused());
        vm.expectRevert(TORC.AlreadyPaused.selector);
        token.pause();
    }

    // Additional: calling unpause() while not paused should revert (covers require branch in _unpause())
    function test_Unpause_WhileNotPaused_Reverts() public {
        assertFalse(token.paused());
        vm.expectRevert(TORC.NotPaused.selector); // custom error
        token.unpause();
    }

    // emergencyWithdrawETH: failed low-level send triggers ETHTransferFailed (line 566)
    function test_EmergencyWithdrawETH_FailedSend_Reverts() public {
        // Seed token contract with ETH
        (bool ok,) = address(token).call{value: 1 ether}("");
        require(ok, "seed eth fail");
        // Recipient that always reverts on receive
        AlwaysRevertRecipient bad = new AlwaysRevertRecipient(address(token));
        vm.expectRevert(TORC.ETHTransferFailed.selector);
        token.emergencyWithdrawETH(0.5 ether, address(bad));
    }

    // Harness: direct internal pause/unpause coverage including double invocations
    function test_PausableHarness_InternalCalls() public {
        PausableHarnessTORC h = new PausableHarnessTORC(address(weth), address(router));
        assertFalse(h.paused());
        h.callInternalPause();
        assertTrue(h.paused());
        vm.expectRevert();
        h.callInternalPause();
        h.callInternalUnpause();
        assertFalse(h.paused());
        vm.expectRevert();
        h.callInternalUnpause();
    }
}
