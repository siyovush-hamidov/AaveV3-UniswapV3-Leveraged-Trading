// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/AaveLeverage.sol";

contract AaveLeverageTest is Test {
    AaveLeverage public leverage;
    
    // Mainnet addresses
    address constant AAVE_LENDING_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2; // AAVE V3 Pool
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // Uniswap V3 Router
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    
    address constant WHALE = 0xf584f8728B874a6a5c7A8d4d387C9aae9172D621; // Адрес с большим количеством WETH и USDC
    
    uint256 initialWethDeposit = 1 ether;
    
    function setUp() public {
        // Форк mainnet
        vm.createSelectFork("mainnet");
        
        // Разворачиваем контракт
        leverage = new AaveLeverage(
            AAVE_LENDING_POOL,
            UNISWAP_ROUTER,
            WETH,
            USDC
        );
        
        // Устанавливаем баланс и одобрения от кита
        vm.startPrank(WHALE);
        deal(WETH, WHALE, 10 ether);
        deal(USDC, WHALE, 10000 * 10**6);
        
        IERC20(WETH).approve(address(leverage), 10 ether);
        IERC20(USDC).approve(address(leverage), 10000 * 10**6);
        vm.stopPrank();
    }
    
    function testManualLeverage() public {
        // Действуем от имени кита
        vm.startPrank(WHALE);
        
        // Исходные балансы
        uint256 initialWethBalance = IERC20(WETH).balanceOf(WHALE);
        
        // Шаг 1: Поставляем WETH в качестве обеспечения
        leverage.supplyCollateral(WETH, initialWethDeposit);
        
        // Шаг 2: Создаем левереджированную позицию
        leverage.createLeveragedLongPosition(3); // 3 итерации
        
        // Получаем данные о счете
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            ,
            uint256 ltv,
            uint256 healthFactor
        ) = leverage.getAccountData();
        
        console.log("--- После ручного левереджа ---");
        console.log("Общее обеспечение (USD):", totalCollateralBase / 1e8);
        console.log("Общий долг (USD):", totalDebtBase / 1e8);
        console.log("Доступно для займа (USD):", availableBorrowsBase / 1e8);
        console.log("Коэффициент LTV (%):", ltv / 100);
        console.log("Коэффициент здоровья:", healthFactor / 1e18);
        
        // Рассчитываем общий левередж
        uint256 leverageRatio = (totalCollateralBase * 1e18) / (totalCollateralBase - totalDebtBase);
        console.log("Коэффициент левереджа: x", leverageRatio / 1e18);
        
        vm.stopPrank();
    }
    
    function testFlashLoanLeverage() public {
        // Действуем от имени кита
        vm.startPrank(WHALE);
        
        // Шаг 1: Поставляем WETH в качестве обеспечения
        leverage.supplyCollateral(WETH, initialWethDeposit);
        
        // Шаг 2: Создаем левереджированную позицию с использованием флеш-кредита
        leverage.createLeveragedPositionWithFlashLoan(1000 * 10**6); // 1000 USDC
        
        // Получаем данные о счете
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            ,
            uint256 ltv,
            uint256 healthFactor
        ) = leverage.getAccountData();
        
        console.log("--- После левереджа с флеш-кредитом ---");
        console.log("Общее обеспечение (USD):", totalCollateralBase / 1e8);
        console.log("Общий долг (USD):", totalDebtBase / 1e8);
        console.log("Доступно для займа (USD):", availableBorrowsBase / 1e8);
        console.log("Коэффициент LTV (%):", ltv / 100);
        console.log("Коэффициент здоровья:", healthFactor / 1e18);
        
        // Рассчитываем общий левередж
        uint256 leverageRatio = (totalCollateralBase * 1e18) / (totalCollateralBase - totalDebtBase);
        console.log("Коэффициент левереджа: x", leverageRatio / 1e18);
        
        vm.stopPrank();
    }
    
    function testMaximumLeverage() public view {
        // Учитывая LTV в 70%, максимальный левередж = 1/(1-0.7) = 3.33x
        uint256 ltv = 70; // 70%
        uint256 maxLeverage = 1e18 / (100 - ltv) * 100;
        
        console.log("При LTV", ltv, "% максимальный теоретический левередж = x", maxLeverage / 1e18);
        
        // Практический максимум обычно ниже из-за рисков ликвидации и газовых издержек
        uint256 safeMaxLeverage = maxLeverage * 90 / 100; // 90% от максимума
        console.log("Безопасный практический левередж = x", safeMaxLeverage / 1e18);
    }
}