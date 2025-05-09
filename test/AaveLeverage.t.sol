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
    uint24 constant AAVE_FLASH_LOAN_FEE = 500;
    uint24 constant SLIPPAGE_BPS = 10000;
    uint256 constant MIN_HEALTH_FACTOR = 1.2e18;
    uint256 constant TARGET_LEVERAGE = 3e18;

    function setUp() public {
        vm.startPrank(WHALE);
        deal(WETH, WHALE, 1 ether);
        deal(USDC, WHALE, 2500 * 1e6);

        leverage = new AaveLeverage(
            AAVE_LENDING_POOL,
            AAVE_DATA_PROVIDER,
            AAVE_ADDRESS_PROVIDER,
            UNISWAP_ROUTER,
            UNISWAP_QUOTER,
            UNISWAP_POOL_FEE,
            AAVE_FLASH_LOAN_FEE,
            WETH,
            USDC
        );

        IERC20(WETH).approve(address(leverage), type(uint256).max);
        IERC20(USDC).approve(address(leverage), type(uint256).max);
        vm.stopPrank();
    }

    function testManualLeverageLong() public {
        vm.startPrank(WHALE);
        uint256 initialWeth = 1 ether;
        leverage.supplyCollateral(WETH, initialWeth);
        leverage.openLeveragedPosition(true, MIN_HEALTH_FACTOR, SLIPPAGE_BPS);

        (uint256 collateral, uint256 debt,, uint256 ltv,,) = leverage.getAccountData();
        assertGt(collateral, 0, "Collateral should be non-zero");
        assertGt(debt, 0, "Debt should be non-zero");
        assertGt(ltv, 0, "LTV should be non-zero");
        printStats();
        vm.stopPrank();
    }

    function testManualLeverageShort() public {
        vm.startPrank(WHALE);
        uint256 initialUsdc = 1500 * 1e6;
        leverage.supplyCollateral(USDC, initialUsdc);
        leverage.openLeveragedPosition(false, MIN_HEALTH_FACTOR, SLIPPAGE_BPS);

        (uint256 collateral, uint256 debt,, uint256 ltv,,) = leverage.getAccountData();
        assertGt(collateral, 0, "Collateral should be non-zero");
        assertGt(debt, 0, "Debt should be non-zero");
        assertGt(ltv, 0, "LTV should be non-zero");
        printStats();
        vm.stopPrank();
    }

    function testFlashLoanLeverageLong() public {
        vm.startPrank(WHALE);
        uint256 initialWeth = 1 ether;
        leverage.supplyCollateral(WETH, initialWeth);
        leverage.openLeveragedPositionFlashLoan(initialWeth, TARGET_LEVERAGE, SLIPPAGE_BPS, true);

        (uint256 collateral, uint256 debt,, uint256 ltv,,) = leverage.getAccountData();
        assertGt(collateral, 0, "Collateral should be non-zero");
        assertGt(debt, 0, "Debt should be non-zero");
        assertGt(ltv, 0, "LTV should be non-zero");
        printStats();
        vm.stopPrank();
    }

    function testFlashLoanLeverageShort() public {
        vm.startPrank(WHALE);
        uint256 initialUsdc = 1500 * 1e6;
        leverage.supplyCollateral(USDC, initialUsdc);
        leverage.openLeveragedPositionFlashLoan(initialUsdc, TARGET_LEVERAGE, SLIPPAGE_BPS, false);

        (uint256 collateral, uint256 debt,,,,) = leverage.getAccountData();
        assertGt(collateral, 0, "Collateral should be non-zero");
        assertGt(debt, 0, "Debt should be non-zero");
        printStats();
        vm.stopPrank();
    }

    // TODO: Closing short position is not working.
    // Reason: After repayment in closePosition, the debt remains almost the same.
    // So, withdrawing funds is not possible. While in the long position, the debt is fully repaid.
    // But it still behaves oddly: In the long position, after repayment,
    // the balance remains almost the same, but the debt is fully repaid.
    // After withdrawing, we get the initially invested funds but with an enormous loss (10-15%).

    // function testFlashLoanLeverageShortAndClose() public {
    //     vm.startPrank(WHALE);
    //     uint256 initialUsdc = 1500 * 1e6;
    //     leverage.supplyCollateral(USDC, initialUsdc);
    //     leverage.openLeveragedPositionFlashLoan(initialUsdc, TARGET_LEVERAGE, SLIPPAGE_BPS, false);
    //     leverage.closePosition(SLIPPAGE_BPS, false);

    //     (uint256 collateral, uint256 debt,, uint256 ltv,,) = leverage.getAccountData();
    //     assertGt(collateral, 0, "Collateral should be non-zero");
    //     assertGt(debt, 0, "Debt should be non-zero");
    //     assertGt(IERC20(USDC).balanceOf(WHALE), 0, "USDC balance should be non-zero");
    //     printStats();
    //     vm.stopPrank();
    // }

    function testManualLeverageLongAndClose() public {
        vm.startPrank(WHALE);
        uint256 initialWeth = 1 ether;
        leverage.supplyCollateral(WETH, initialWeth);
        leverage.openLeveragedPosition(true, MIN_HEALTH_FACTOR, SLIPPAGE_BPS);
        leverage.closePosition(SLIPPAGE_BPS, true);

        (uint256 collateral, uint256 debt,,,,) = leverage.getAccountData();
        assertEq(debt, 0, "Debt should be zero after closing");
        assertEq(collateral, 0, "Collateral should be zero after closing");
        assertGt(IERC20(WETH).balanceOf(WHALE), 0, "WETH balance should be non-zero");
        printStats();
        vm.stopPrank();
    }

    function testFlashLoanLeverageLongAndClose() public {
        vm.startPrank(WHALE);
        uint256 initialWeth = 1 ether;
        leverage.supplyCollateral(WETH, initialWeth);
        leverage.openLeveragedPositionFlashLoan(initialWeth, TARGET_LEVERAGE, SLIPPAGE_BPS, true);
        leverage.closePosition(SLIPPAGE_BPS, true);

        (uint256 collateral, uint256 debt,,,,) = leverage.getAccountData();
        assertEq(debt, 0, "Debt should be zero after closing");
        assertEq(collateral, 0, "Collateral should be zero after closing");
        assertGt(IERC20(WETH).balanceOf(WHALE), 0, "WETH balance should be non-zero");
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
    }
}
