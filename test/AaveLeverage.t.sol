// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/AaveLeverage.sol";

contract AaveLeverageTest is Test {
    AaveLeverage public leverage;
    address constant WHALE = 0xf584F8728B874a6a5c7A8d4d387C9aae9172D621;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant AAVE_LENDING_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address constant AAVE_ADDRESS_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant UNISWAP_QUOTER = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;

    uint24 constant UNISWAP_POOL_FEE = 3000;
    uint24 constant SLIPPAGE_BPS = 10000;
    uint256 constant MIN_HEALTH_FACTOR = 1.2e18;
    uint256 constant TARGET_LEVERAGE = 3e18;

    function setUp() public {
        vm.startPrank(WHALE);
        deal(WETH, WHALE, 10 ether);
        deal(USDC, WHALE, 10000 * 1e6);

        leverage = new AaveLeverage(
            AAVE_LENDING_POOL,
            AAVE_DATA_PROVIDER,
            AAVE_ADDRESS_PROVIDER,
            UNISWAP_ROUTER,
            UNISWAP_QUOTER,
            UNISWAP_POOL_FEE,
            WETH,
            USDC
        );

        IERC20(WETH).approve(address(leverage), type(uint256).max);
        IERC20(USDC).approve(address(leverage), type(uint256).max);
        vm.stopPrank();
    }

    function testIterativeLeverageLong() public {
        vm.startPrank(WHALE);
        uint256 initialWeth = 5 ether;
        leverage.supplyCollateral(WETH, initialWeth);
        leverage.openLeveragedPosition(MIN_HEALTH_FACTOR, SLIPPAGE_BPS, true);
        printStats();
        vm.stopPrank();
    }

    function testIterativeLeverageLongAndClose() public {
        vm.startPrank(WHALE);
        uint256 initialWeth = 5 ether;
        leverage.supplyCollateral(WETH, initialWeth);
        leverage.openLeveragedPosition(MIN_HEALTH_FACTOR, SLIPPAGE_BPS, true);
        leverage.closePosition(SLIPPAGE_BPS, true);
        assertGt(IERC20(WETH).balanceOf(WHALE), 0, "WETH balance should be non-zero");
        printStats();
        vm.stopPrank();
    }

    function testIterativeLeverageShort() public {
        vm.startPrank(WHALE);
        uint256 initialUsdc = 5000 * 1e6;
        leverage.supplyCollateral(USDC, initialUsdc);
        leverage.openLeveragedPosition(MIN_HEALTH_FACTOR, SLIPPAGE_BPS, false);
        printStats();
        vm.stopPrank();
    }

    function testIterativeLeverageShortAndClose() public {
        vm.startPrank(WHALE);
        uint256 initialUsdc = 5000 * 1e6;
        leverage.supplyCollateral(USDC, initialUsdc);
        leverage.openLeveragedPosition(MIN_HEALTH_FACTOR, SLIPPAGE_BPS, false);
        leverage.closePosition(SLIPPAGE_BPS, false);
        assertGt(IERC20(USDC).balanceOf(WHALE), 0, "USDC balance should be non-zero");
        printStats();
        vm.stopPrank();
    }

    function testFlashLoanLeverageLong() public {
        vm.startPrank(WHALE);
        uint256 initialWeth = 5 ether;
        leverage.supplyCollateral(WETH, initialWeth);
        leverage.openLeveragedPositionFlashLoan(initialWeth, TARGET_LEVERAGE, SLIPPAGE_BPS, true);
        printStats();
        vm.stopPrank();
    }

    function testFlashLoanLeverageLongAndClose() public {
        vm.startPrank(WHALE);
        uint256 initialWeth = 5 ether;
        leverage.supplyCollateral(WETH, initialWeth);
        leverage.openLeveragedPositionFlashLoan(initialWeth, TARGET_LEVERAGE, SLIPPAGE_BPS, true);
        leverage.closePosition(SLIPPAGE_BPS, true);
        assertGt(IERC20(WETH).balanceOf(WHALE), 0, "WETH balance should be non-zero");
        printStats();
        vm.stopPrank();
    }

    function testFlashLoanLeverageShort() public {
        vm.startPrank(WHALE);
        uint256 initialUsdc = 5000 * 1e6;
        leverage.supplyCollateral(USDC, initialUsdc);
        leverage.openLeveragedPositionFlashLoan(initialUsdc, TARGET_LEVERAGE, SLIPPAGE_BPS, false);
        printStats();
        vm.stopPrank();
    }

    function testFlashLoanLeverageShortAndClose() public {
        vm.startPrank(WHALE);
        uint256 initialUsdc = 5000 * 1e6;
        leverage.supplyCollateral(USDC, initialUsdc);
        leverage.openLeveragedPositionFlashLoan(initialUsdc, TARGET_LEVERAGE, SLIPPAGE_BPS, false);
        leverage.closePosition(SLIPPAGE_BPS, false);
        assertGt(IERC20(USDC).balanceOf(WHALE), 0, "USDC balance should be non-zero");
        printStats();
        vm.stopPrank();
    }

    function printStats() private view {
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            ,
            uint256 ltv,
            uint256 healthFactor
        ) = leverage.getAccountData();
        console.log("\n=== Position Snapshot ===");
        console.log("Block timestamp:", block.timestamp);
        console.log("Collateral: $", totalCollateralBase / 1e8);
        console.log("Debt: $", totalDebtBase / 1e8);
        console.log("Health factor:", healthFactor);
        console.log("Available to borrow:", availableBorrowsBase);
        console.log("LTV ratio (%):", ltv);
        if (totalCollateralBase > totalDebtBase) {
            console.log("Leverage ratio: x", totalCollateralBase * 1e18 / (totalCollateralBase - totalDebtBase));
        }
        console.log("Balance (USDC): ", IERC20(USDC).balanceOf(WHALE));
        console.log("Balance (WETH): ", IERC20(WETH).balanceOf(WHALE));
    }
}
