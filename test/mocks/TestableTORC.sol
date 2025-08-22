// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {TORC} from "../../src/TORC.sol";

/// @notice Test harness exposing internal _accrueDistribution for targeted branch coverage.
contract TestableTORC is TORC {
    constructor(address _weth, address _router) TORC(_weth, _router) {}

    function callAccrueDistribution(uint256 amount) external onlyRole(FEE_MANAGER_ROLE) {
        _accrueDistribution(amount);
    }
}
