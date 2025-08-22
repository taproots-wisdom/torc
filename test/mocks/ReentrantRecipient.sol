// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITORC {
    function distributeFees(uint256 amount) external;
    function claimFees() external;
}

/// @notice Reverts on push payouts (to force pending), but accepts ETH during claim.
contract ReentrantRecipient {
    ITORC public immutable token;

    // Controls whether receive() reverts.
    bool public revertOnReceive = true;

    constructor(address _token) {
        token = ITORC(_token);
    }

    receive() external payable {
        // Try to reenter; should be blocked by nonReentrant.
        try token.distributeFees(1) {} catch {}
        // For push payouts we want to fail so it accrues to pending.
        if (revertOnReceive) {
            revert("reentrant-receiver: revert");
        }
        // When revertOnReceive == false (during claim), accept ETH.
    }

    function claim() external {
        // Temporarily allow receiving ETH
        bool prev = revertOnReceive;
        revertOnReceive = false;
        token.claimFees();
        // Restore behavior
        revertOnReceive = prev;
    }
}
