// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface ILendingPoolAddressesProvider {
    function getPriceOracle() external view returns (address);
}
