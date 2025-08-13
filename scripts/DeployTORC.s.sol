// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {TORC} from "../src/TORC.sol";

/// @title DeployTORC Script
/// @notice
/// Reads configuration from environment variables (see below), deploys TORC,
/// and optionally configures pair, fee split, swap fee, and distribution threshold.
///
/// ### Required .env
/// - WETH ................ address (e.g. mainnet WETH: 0xC02aaA39... )
/// - UNIV2_ROUTER ........ address (e.g. 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D)
///
/// ### Optional .env
/// - FEE_RECIPIENT ....... address (defaults to the deployer)
/// - FEE_BPS ............. uint (defaults to 10000 = 100%)
/// - SWAP_FEE_BPS ........ uint (defaults to 300 = 3.00%, max 1000)
/// - FEE_THRESHOLD_WEI ... uint (defaults to 0 = no auto-accrual trigger)
/// - PAIR_ADDRESS ........ address (if known; can be set later)
///
/// ### Usage
/// forge script script/DeployTORC.s.sol \
///   --rpc-url $RPC_URL \
///   --private-key $DEPLOYER_PRIVATE_KEY \
///   --broadcast -vv
contract DeployTORC is Script {
    function run() external {
        // --------- Load env ----------
        address WETH         = vm.envAddress("WETH");
        address UNIV2_ROUTER = vm.envAddress("UNIV2_ROUTER");

        // Optional params with sane defaults
        address FEE_RECIPIENT      = vm.envOr("FEE_RECIPIENT", address(0));
        uint256 FEE_BPS            = vm.envOr("FEE_BPS", uint256(10_000)); // 100%
        uint256 SWAP_FEE_BPS       = vm.envOr("SWAP_FEE_BPS", uint256(300)); // 3%
        uint256 FEE_THRESHOLD_WEI  = vm.envOr("FEE_THRESHOLD_WEI", uint256(0));
        address PAIR_ADDRESS       = vm.envOr("PAIR_ADDRESS", address(0));

        // --------- Broadcast ----------
        vm.startBroadcast();

        // 1) Deploy TORC (deployer gets DEFAULT_ADMIN_ROLE, PAUSER_ROLE, FEE_MANAGER_ROLE, TGE_MANAGER_ROLE)
        TORC token = new TORC(WETH, UNIV2_ROUTER);

        // 2) Optional: set router swap fee (bps) if different from default
        if (SWAP_FEE_BPS != 300) {
            token.setSwapFee(SWAP_FEE_BPS);
        }

        // 3) Optional: set fee distribution threshold (in wei)
        if (FEE_THRESHOLD_WEI > 0) {
            token.setFeeDistributionThreshold(FEE_THRESHOLD_WEI);
        }

        // 4) Optional: set the pair (can be set later once LP is created)
        if (PAIR_ADDRESS != address(0)) {
            token.setPairAddress(PAIR_ADDRESS);
        }

        // 5) Fee recipients: default to (deployer, 100%) if none provided
        {
            address recipient = FEE_RECIPIENT == address(0) ? msg.sender : FEE_RECIPIENT;
            uint256 bps = FEE_BPS == 0 ? 10_000 : FEE_BPS;

            address;
            uint256;
            recs[0] = recipient;
            bpsArr[0] = bps;
            token.setFeeRecipients(recs, bpsArr);
        }

        vm.stopBroadcast();

        // --------- Logs ----------
        console2.log("TORC deployed at:", address(token));
        console2.log("  WETH:           ", WETH);
        console2.log("  Router:         ", UNIV2_ROUTER);
        console2.log("  SwapFeeBps:     ", SWAP_FEE_BPS);
        console2.log("  FeeThresholdWei:", FEE_THRESHOLD_WEI);
        console2.log("  Pair:           ", PAIR_ADDRESS);
    }
}
