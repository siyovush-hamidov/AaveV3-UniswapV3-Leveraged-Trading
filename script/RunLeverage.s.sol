// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/AaveLeverage.sol";

contract RunLeverageScript is Script {
    // Mainnet addresses
    address constant AAVE_LENDING_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2; // AAVE V3 Pool
    address constant AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3; // AAVE V3 Data Provider
    address constant AAVE_ADDRESS_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // Uniswap V3 Router
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function run() public {
        // Начинаем транзакцию от имени скрипта
        vm.startBroadcast();

        // Разворачиваем контракт
        AaveLeverage leverage =
            new AaveLeverage(AAVE_LENDING_POOL, AAVE_DATA_PROVIDER, AAVE_ADDRESS_PROVIDER, UNISWAP_ROUTER, WETH, USDC);

        console.log("AaveLeverage deployed at:", address(leverage));

        vm.stopBroadcast();
    }
}
