// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {TORC} from "../src/TORC.sol";

/// @title DeployTORC on Sepolia
/// @notice
/// Deploys TORC on Sepolia using Uniswap V2-style router + WETH.
/// Defaults are the known Sepolia testnet addresses below, but you can override
/// them in your .env (see "Env variables").
///
/// Default Sepolia addresses:
/// - WETH (Wrapped ETH):          0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9
/// - UniswapV2 Router (periphery):0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008
///
/// ### Env variables (optional overrides)
/// - SEPOLIA_WETH ............. address (defaults to constant above)
/// - SEPOLIA_UNIV2_ROUTER ..... address (defaults to constant above)
/// - FEE_RECIPIENT ............ address (defaults to deployer)
/// - FEE_BPS .................. uint (defaults 10000 = 100%)
/// - SWAP_FEE_BPS ............. uint (defaults 300 = 3%, max 1000)
/// - FEE_THRESHOLD_WEI ........ uint (defaults 0 = no auto-accrual trigger)
/// - PAIR_ADDRESS ............. address (optional; set later after LP if unknown)
///
/// ### Usage (broadcast to Sepolia)
/// forge script script/DeployTORC_Sepolia.s.sol \
///   --rpc-url $SEPOLIA_RPC_URL \
///   --private-key $DEPLOYER_PRIVATE_KEY \
///   --broadcast -vv
contract DeployTORC_Sepolia is Script {
    // Defaults for Sepolia
    address constant DEFAULT_SEPOLIA_WETH         = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address constant DEFAULT_SEPOLIA_UNIV2_ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;

    function run() external {
        // --- Load env or fall back to Sepolia defaults ---
        address WETH = vm.envOr("SEPOLIA_WETH", DEFAULT_SEPOLIA_WETH);
        address UNIV2_ROUTER = vm.envOr("SEPOLIA_UNIV2_ROUTER", DEFAULT_SEPOLIA_UNIV2_ROUTER);

        address FEE_RECIPIENT = vm.envOr("FEE_RECIPIENT", address(0));
        uint256 FEE_BPS = vm.envOr("FEE_BPS", uint256(10_000));            // 100%
        uint256 SWAP_FEE_BPS = vm.envOr("SWAP_FEE_BPS", uint256(300));      // 3%
        uint256 FEE_THRESHOLD_WEI = vm.envOr("FEE_THRESHOLD_WEI", uint256(0));
        address PAIR_ADDRESS = vm.envOr("PAIR_ADDRESS", address(0));

        vm.startBroadcast();

        // 1) Deploy TORC
        TORC token = new TORC(WETH, UNIV2_ROUTER);

        // 2) Configure swap fee if non-default
        if (SWAP_FEE_BPS != 300) {
            token.setSwapFee(SWAP_FEE_BPS);
        }

        // 3) Threshold (optional)
        if (FEE_THRESHOLD_WEI > 0) {
            token.setFeeDistributionThreshold(FEE_THRESHOLD_WEI);
        }

        // 4) Set pair now if already known; otherwise set after you create LP
        if (PAIR_ADDRESS != address(0)) {
            token.setPairAddress(PAIR_ADDRESS);
        }

        // 5) Fee split (defaults to deployer 100%)
        {
            address recipient = FEE_RECIPIENT == address(0) ? msg.sender : FEE_RECIPIENT;
            uint256 bps = FEE_BPS == 0 ? 10_000 : FEE_BPS;

            address[] memory recs = new address[](1);
            uint256[] memory bpsArr = new uint256[](1);
            recs[0] = recipient;
            bpsArr[0] = bps;
            token.setFeeRecipients(recs, bpsArr);
        }

        vm.stopBroadcast();

        console2.log("== TORC deployed to Sepolia ==");
        console2.log("TORC:", address(token));
        console2.log("WETH:", WETH);
        console2.log("Router:", UNIV2_ROUTER);
        console2.log("SwapFeeBps:", SWAP_FEE_BPS);
        console2.log("FeeThresholdWei:", FEE_THRESHOLD_WEI);
        console2.log("Pair:", PAIR_ADDRESS);
    }
}
