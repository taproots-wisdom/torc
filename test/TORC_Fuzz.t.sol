// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "lib/forge-std/src/Test.sol";
import {TORC} from "../src/TORC.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract TORC_Fuzz is Test {
    TORC token;
    MockRouter router;
    MockWETH weth;

    address payable constant ALICE = payable(address(uint160(uint256(keccak256("ALICE")))));
    address payable constant BOB = payable(address(uint160(uint256(keccak256("BOB")))));
    address payable constant CAROL = payable(address(uint160(uint256(keccak256("CAROL")))));
    address constant PAIR = address(uint160(uint256(keccak256("PAIR"))));

    // --- EIP-712/2612 helpers for permit fuzz ---
    bytes32 constant _EIP712DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        weth = new MockWETH();
        router = new MockRouter();
        token = new TORC(address(weth), address(router));

        // configure pair
        token.setPairAddress(PAIR);

        // simple TGE (mint to ALICE big supply for fuzz)
        address[] memory recs = new address[](1);
        uint256[] memory amts = new uint256[](1);
        recs[0] = ALICE;
        amts[0] = 100_000_000; // 100m * 1e18
        token.configureTGE(recs, amts);
        token.executeTGE();

        // fund router to pay ETH outs
        vm.deal(address(router), 10_000 ether);

        // default recipients (100% → BOB) so distribution checks are simple
        address[] memory fr = new address[](1);
        uint256[] memory fb = new uint256[](1);
        fr[0] = BOB;
        fb[0] = 10_000;
        token.setFeeRecipients(fr, fb);
    }

    // ------------------------------------------------------------
    // Fuzz: fee logic on pair transfers
    // ------------------------------------------------------------

    function testFuzz_FeeOnSell_PairTouch(uint256 amount, uint16 feeBps) public {
        // Bound inputs
        feeBps = uint16(bound(feeBps, 0, 1000)); // <=10%
        amount = bound(amount, 1e18, 1_000_000_000e18); // 1 to 1b TORC

        token.setSwapFee(feeBps);

        // Give ALICE enough balance
        // (already has huge TGE, but bounding again is fine)
        vm.prank(ALICE);
        token.transfer(ALICE, 0); // touch (no-op) keeps compiler happy

        uint256 aliceBefore = token.balanceOf(ALICE);
        if (aliceBefore < amount) {
            // top up if needed (mint via fresh TGE in a new instance would be heavy; instead, reduce amount)
            amount = aliceBefore;
        }
        vm.assume(amount > 0);

        // ALICE sells to PAIR (collects fee)
        vm.prank(ALICE);
        token.transfer(PAIR, amount);

        uint256 expectedFee = (amount * feeBps) / 10_000;
        assertEq(token.balanceOf(address(token)), expectedFee, "fee mismatch");
        // Net delivered to PAIR:
        assertEq(token.balanceOf(PAIR), amount - expectedFee, "net-to-pair mismatch");
    }

    function testFuzz_FeeExempt_NoFee(uint256 amount) public {
        amount = bound(amount, 1e18, 5_000_000e18);

        token.setFeeExempt(ALICE, true);
        uint256 before = token.balanceOf(address(token));

        vm.prank(ALICE);
        token.transfer(PAIR, amount);

        assertEq(token.balanceOf(address(token)), before, "no fee expected for exempt");
    }

    // ------------------------------------------------------------
    // Fuzz: recipients split math + real processing via mock router
    // ------------------------------------------------------------

    function testFuzz_SplitMath_And_Distribution(uint16 aBps, uint256 sellAmount) public {
        // Pick two-recipient split [a, 10_000-a]
        aBps = uint16(bound(aBps, 0, 10_000));
        uint16 bBps = uint16(10_000 - aBps);

        address[] memory recs = new address[](2);
        uint256[] memory bps = new uint256[](2);
        recs[0] = BOB;
        bps[0] = aBps;
        recs[1] = CAROL;
        bps[1] = bBps;
        token.setFeeRecipients(recs, bps);

        // Create fees with a sell
        sellAmount = bound(sellAmount, 10_000e18, 10_000_000e18);
        vm.prank(ALICE);
        token.transfer(PAIR, sellAmount);

        uint256 torcFees = token.balanceOf(address(token));
        if (torcFees == 0) return; // swapFeeBps may be 0 from another fuzz run

        // Process -> convert to ETH at router RATE_DIV=1000 (mock)
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        uint256 accrued = token.accumulatedFeeWei();
        if (accrued == 0) return;

        uint256 bobBefore = BOB.balance;
        uint256 carBefore = CAROL.balance;

        token.distributeFees(accrued);

        uint256 bobGot = BOB.balance - bobBefore;
        uint256 carGot = CAROL.balance - carBefore;

        // Expected splits
        assertEq(bobGot, (accrued * aBps) / 10_000, "bob share");
        assertEq(carGot, (accrued * bBps) / 10_000, "carol share");

        // Allow up to recipients.length - 1 wei of dust to remain due to per-term flooring.
        uint256 leftover = token.accumulatedFeeWei();
        assertLe(leftover, recs.length - 1, "residual dust too large");
    }

    // ------------------------------------------------------------
    // Fuzz: distributeFeesRange guards
    // ------------------------------------------------------------

    function testFuzz_DistributeFeesRange_Indices(uint16 start, uint16 end) public {
        // Prepare recipients: 3 addrs with 40/30/30
        address[] memory recs = new address[](3);
        uint256[] memory bps = new uint256[](3);
        recs[0] = ALICE;
        bps[0] = 4000;
        recs[1] = BOB;
        bps[1] = 3000;
        recs[2] = CAROL;
        bps[2] = 3000;
        token.setFeeRecipients(recs, bps);

        // Create + process some fees so there is ETH to distribute
        vm.prank(ALICE);
        token.transfer(PAIR, 100_000e18);
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        vm.assume(token.accumulatedFeeWei() > 0);

        // fuzz indices
        uint256 len = 3;
        start = uint16(bound(start, 0, 5));
        end = uint16(bound(end, 0, 5));

        if (start >= end || end > len) {
            vm.expectRevert(TORC.LengthMismatch.selector);
            token.distributeFeesRange(1 ether, start, end);
        } else {
            // should succeed and not revert
            token.distributeFeesRange(1 ether, start, end);
        }
    }

    // ------------------------------------------------------------
    // Fuzz: EIP-2612 – permit() -> transferFrom()
    // ------------------------------------------------------------

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _EIP712DOMAIN_TYPEHASH,
                keccak256(bytes(token.name())),
                keccak256(bytes("1")),
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
        bytes32 structHash =
            keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, token.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        return vm.sign(pk, digest);
    }

    /// @notice Fuzz the owner key + approved value (bounded to valid secp and owner balance)
    function testFuzz_Permit_ApproveAndPull(uint256 rawPk, uint256 rawApprove, uint256 rawPull) public {
        // Bound pk to (1..secp256k1n-1)
        // secp n ≈ 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
        uint256 N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        rawPk = bound(rawPk, 1, N - 1);
        address owner = vm.addr(rawPk);

        // give owner tokens
        vm.prank(ALICE);
        token.transfer(owner, 1_000e18);

        uint256 approveValue = bound(rawApprove, 0, token.balanceOf(owner)); // can approve 0 too
        uint256 deadline = block.timestamp + 1 days;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(rawPk, owner, BOB, approveValue, deadline);

        // Execute permit
        token.permit(owner, BOB, approveValue, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), approveValue);

        // Pull an amount ≤ approved and ≤ balance
        uint256 pull = bound(rawPull, 0, approveValue);
        vm.prank(BOB);
        if (pull == 0) {
            // zero transfers are valid, but skip exercising if zero to avoid useless work
            return;
        }
        token.transferFrom(owner, BOB, pull);

        assertEq(token.balanceOf(BOB), pull);
        assertEq(token.allowance(owner, BOB), approveValue - pull);
    }

    // ------------------------------------------------------------
    // Fuzz: default swap path customization
    // ------------------------------------------------------------

    function testFuzz_DefaultPath_CustomMiddleHop(address middle) public {
        // Ensure middle hop is not zero and not TORC/WETH duplicates
        vm.assume(middle != address(0));
        vm.assume(middle != address(token));
        vm.assume(middle != address(weth));

        address[] memory path = new address[](3);
        path[0] = address(token);
        path[1] = middle;
        path[2] = address(weth);

        token.setDefaultSwapPath(path);

        // Create some fee, then process using default (custom) path
        vm.prank(ALICE);
        token.transfer(PAIR, 50_000e18);

        // If router supports arbitrary middle hop in mock, this succeeds (mock ignores path content)
        token.processFees(0, 0, new address[](0), block.timestamp + 300);
        assertGt(token.accumulatedFeeWei(), 0, "expected ETH accrued via custom path");
    }
}
