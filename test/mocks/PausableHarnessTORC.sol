// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {TORC} from "../../src/TORC.sol";

// Harness exposing internal _pause/_unpause for direct coverage.
contract PausableHarnessTORC is TORC {
    constructor(address _weth, address _router) TORC(_weth, _router) {}

    function callInternalPause() external {
        _pause();
    }

    function callInternalUnpause() external {
        _unpause();
    }
}
