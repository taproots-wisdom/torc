// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockRouter {
    bool public revertSwaps;
    address public lastTo;

    /// 1000 TORC (in wei) -> 1 ETH (in wei)
    uint256 public RATE_DIV = 1000;

    function setRevert(bool v) external { revertSwaps = v; }
    function setRateDiv(uint256 v) external { require(v > 0, "rate=0"); RATE_DIV = v; }

    receive() external payable {}

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /*deadline*/
    ) external returns (uint256[] memory amounts) {
        require(!revertSwaps, "router: revert");
        require(path.length >= 2, "path");

        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);

        uint256 ethOut = amountIn / RATE_DIV; // e.g., 3000e18 / 1000 = 3e18
        if (ethOut > address(this).balance) ethOut = address(this).balance;
        require(ethOut >= amountOutMin, "slippage");

        lastTo = to;
        (bool ok, ) = to.call{value: ethOut}("");
        require(ok, "eth out");

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = ethOut;
    }
}
