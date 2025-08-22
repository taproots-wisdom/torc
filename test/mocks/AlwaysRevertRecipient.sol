// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {TORC} from "../../src/TORC.sol";

/// @notice Recipient whose receive() always reverts, to exercise ETHTransferFailed path in claimFees.
contract AlwaysRevertRecipient {
    TORC public immutable token;

    constructor(address _token) {
        // Cast to payable because TORC has a payable receive() making its type require a payable address
        token = TORC(payable(_token));
    }

    receive() external payable {
        revert("Always revert on receive");
    }

    function claim() external {
        token.claimFees();
    }
}
