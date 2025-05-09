// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IUniswapV3Oracle {
    function getAssetPrice(address asset) external view returns (uint256);
}
