// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {TORC} from "../../src/TORC.sol";

// Test harness to manipulate decimals between configureTGE and executeTGE
contract DecimalsMutateTORC is TORC {
    uint8 private _decimalsOverride;

    constructor(address _weth, address _router, uint8 initialDecimals) TORC(_weth, _router) {
        _decimalsOverride = initialDecimals;
    }

    function setDecimals(uint8 newDecimals) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _decimalsOverride = newDecimals;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsOverride;
    }
}
