// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/AaveLeverage.sol";

contract AaveLeverageTest is Test {
    AaveLeverage public leverage;

    // Mainnet addresses
    address constant AAVE_LENDING_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2; // AAVE V3 Pool
    address constant AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address constant AAVE_ADDRESS_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // Uniswap V3 Router
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WHALE = 0xf584F8728B874a6a5c7A8d4d387C9aae9172D621; // Адрес с большим количеством WETH и USDC

    // uint256 initialWethDeposit = 1 ether;

    function setUp() public {
        // Форк mainnet
        // vm.createSelectFork("mainnet");
        vm.startPrank(WHALE);
        // Разворачиваем контракт
        leverage =
            new AaveLeverage(AAVE_LENDING_POOL, AAVE_DATA_PROVIDER, AAVE_ADDRESS_PROVIDER, UNISWAP_ROUTER, WETH, USDC);
        // Устанавливаем баланс и одобрения от кита
        deal(WETH, WHALE, 1 ether);
        deal(USDC, WHALE, 1000 * 1e6);

        IERC20(WETH).approve(address(leverage), type(uint256).max);
        IERC20(USDC).approve(address(leverage), type(uint256).max);
        vm.stopPrank();
    }

    function testManualLeverageLong() public {
        // Действуем от имени кита
        vm.startPrank(WHALE);
        // Исходные балансы
        uint256 initialWethBalance = IERC20(WETH).balanceOf(WHALE);
        // Шаг 1: Поставляем WETH в качестве обеспечения
        leverage.supplyCollateral(WETH, initialWethBalance);
        // Шаг 2: Создаем левереджированную позицию
        leverage.openLeveragedPosition(true);

        // Получаем данные о счете
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            ,
            uint256 ltv,
            uint256 healthFactor
        ) = leverage.getAccountData();

        console.log("\nAfter manual leverage: ");
        console.log("Total collateral (USD):", totalCollateralBase / 1e8);
        console.log("Total debt (USD):", totalDebtBase / 1e8);
        console.log("Available to borrow (USD):", availableBorrowsBase / 1e8);
        console.log("LTV ratio (%):", ltv);
        console.log("Health factor:", healthFactor);

        // Рассчитываем общий левередж
        uint256 leverageRatio = (totalCollateralBase * 1e18) / (totalCollateralBase - totalDebtBase);
        console.log("Leverage ratio: x", leverageRatio);

        vm.stopPrank();
    }

    function testManualLeverageShort() public {
        // Действуем от имени кита
        vm.startPrank(WHALE);
        // Исходные балансы
        uint256 initialUsdcBalance = IERC20(USDC).balanceOf(WHALE);
        // Шаг 1: Поставляем WETH в качестве обеспечения
        leverage.supplyCollateral(USDC, initialUsdcBalance);
        // Шаг 2: Создаем левереджированную позицию
        leverage.openLeveragedPosition(false);

        // Получаем данные о счете
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            ,
            uint256 ltv,
            uint256 healthFactor
        ) = leverage.getAccountData();

        console.log("\nAfter manual leverage: ");
        console.log("Total collateral (USD):", totalCollateralBase / 1e8);
        console.log("Total debt (USD):", totalDebtBase / 1e8);
        console.log("Available to borrow (USD):", availableBorrowsBase / 1e8);
        console.log("LTV ratio (%):", ltv);
        console.log("Health factor:", healthFactor);

        // Рассчитываем общий левередж
        uint256 leverageRatio = (totalCollateralBase * 1e18) / (totalCollateralBase - totalDebtBase);
        console.log("Leverage ratio: x", leverageRatio);

        vm.stopPrank();
    }

    function testFlashLoanLeverage() public {
        // Действуем от имени кита
        vm.startPrank(WHALE);

        // Шаг 1: Поставляем WETH в качестве обеспечения
        // leverage.supplyCollateral(WETH, initialWethDeposit);

        // Шаг 2: Создаем левереджированную позицию с использованием флеш-кредита
        // leverage.createLeveragedPositionWithFlashLoan(1000 * 10 ** 6); // 1000 USDC

        // Получаем данные о счете
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            ,
            uint256 ltv,
            uint256 healthFactor
        ) = leverage.getAccountData();

        console.log("--- After flash loan leverage ---");
        console.log("Total collateral (USD):", totalCollateralBase / 1e8);
        console.log("Total debt (USD):", totalDebtBase / 1e8);
        console.log("Available to borrow (USD):", availableBorrowsBase / 1e8);
        console.log("LTV ratio (%):", ltv / 100);
        console.log("Health factor:", healthFactor / 1e18);

        // Рассчитываем общий левередж
        uint256 leverageRatio = (totalCollateralBase * 1e18) / (totalCollateralBase - totalDebtBase);
        console.log("Leverage ratio: x", leverageRatio / 1e18);

        vm.stopPrank();
    }

    function testMaximumLeverage() public view {
        // Учитывая LTV в 70%, максимальный левередж = 1/(1-0.7) = 3.33x
        uint256 ltv = 70; // 70%
        uint256 maxLeverage = (1e18 / (100 - ltv)) * 100;

        console.log("With LTV", ltv, "%, the maximum theoretical leverage = x", maxLeverage / 1e18);

        // Практический максимум обычно ниже из-за рисков ликвидации и газовых издержек
        uint256 safeMaxLeverage = (maxLeverage * 90) / 100; // 90% от максимума
        console.log("Safe practical leverage = x", safeMaxLeverage / 1e18);
    }
}
