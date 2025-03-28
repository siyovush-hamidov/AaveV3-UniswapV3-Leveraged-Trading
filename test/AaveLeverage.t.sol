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
    address constant UNISWAP_QUOTER = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WHALE = 0xf584F8728B874a6a5c7A8d4d387C9aae9172D621; // Адрес с большим количеством WETH и USDC

    function setUp() public {
        vm.startPrank(WHALE);

        deal(WETH, WHALE, 1 ether);
        deal(USDC, WHALE, 2500 * 1e6);

        uint24 UNISWAP_POOL_FEE = 3000;

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

    function testManualLeverageLong() public {
        vm.startPrank(WHALE);

        uint256 initialWethBalance = IERC20(WETH).balanceOf(WHALE);
        leverage.supplyCollateral(WETH, initialWethBalance);
        leverage.openLeveragedPosition(true, 1.2e18);

        printStats();
        vm.stopPrank();
    }

    function testManualLeverageShort() public {
        vm.startPrank(WHALE);

        uint256 initialUsdcBalance = IERC20(USDC).balanceOf(WHALE);
        leverage.supplyCollateral(USDC, initialUsdcBalance);
        leverage.openLeveragedPosition(false, 1.2e18);

        printStats();
        vm.stopPrank();
    }

    function testFlashLoanLeverageLong() public {
        uint256 initialWethDeposit = 0.5 ether;
        uint256 usdcAmountForFlashLoan = 4040 * 1e6;

        vm.startPrank(WHALE);
        leverage.supplyCollateral(WETH, initialWethDeposit);
        leverage.openLeveragedPositionFlashLoan(usdcAmountForFlashLoan, true);

        printStats();
        vm.stopPrank();
    }

    function testFlashLoanLeverageShort() public {
        uint256 initialUsdcDeposit = 1000 * 1e6;
        uint256 wethAmountForFlashLoan = 1 ether;

        vm.startPrank(WHALE);
        leverage.supplyCollateral(USDC, initialUsdcDeposit);
        leverage.openLeveragedPositionFlashLoan(wethAmountForFlashLoan, false);

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
        console.log("Total collateral (USD * 1e8):", totalCollateralBase);
        console.log("Total debt (USD):", totalDebtBase);
        console.log("Available to borrow (USD):", availableBorrowsBase);
        console.log("LTV ratio (%):", ltv);
        console.log("Health factor:", healthFactor);
        console.log("Leverage ratio: x", totalCollateralBase * 1e18 / (totalCollateralBase - totalDebtBase));
    }
}
