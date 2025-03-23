// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "forge-std/Test.sol";

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IAaveProtocolDataProvider {
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveDecimals,
            uint256 reserveFactor
        );
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IFlashLoanReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

contract AaveLeverage is IFlashLoanReceiver {
    using SafeERC20 for IERC20;

    address public owner;
    IPool public lendingPool;
    IAaveProtocolDataProvider public dataProvider;
    ISwapRouter public swapRouter;

    address public wethAddress;
    address public usdcAddress;
    uint24 public constant POOL_FEE = 3000;

    constructor(address _lendingPool, address _dataProvider, address _swapRouter, address _weth, address _usdc) {
        owner = msg.sender;
        lendingPool = IPool(_lendingPool);
        dataProvider = IAaveProtocolDataProvider(_dataProvider);
        swapRouter = ISwapRouter(_swapRouter);
        wethAddress = _weth;
        usdcAddress = _usdc;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    function supplyCollateral(address asset, uint256 amount) external onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).approve(address(lendingPool), amount);
        IERC20(asset).approve(address(lendingPool), type(uint256).max);
        lendingPool.supply(asset, amount, address(this), 0);
    }

    function getMaxBorrowAmount(address borrowAsset) public view returns (uint256) {
        // Get available borrow base amount (in USD)
        (,, uint256 availableBorrowsBase,,,) = lendingPool.getUserAccountData(address(this));
        console.log("availableBorrowsBase: ", availableBorrowsBase);

        // Get reserve decimals for the asset we want to borrow
        (uint256 reserveDecimals,,,,) = dataProvider.getReserveConfigurationData(borrowAsset);
        console.log("reserveDecimals: ", reserveDecimals);
        // Base currency (USD) uses 8 decimals in Aave V3
        uint256 baseDecimals = 8;

        // Convert from base currency to token amount
        // If base is 8 decimals and USDC is 6, we divide by 10^2
        if (baseDecimals > reserveDecimals) {
            return availableBorrowsBase / (10 ** (baseDecimals - reserveDecimals));
        } else {
            return availableBorrowsBase * (10 ** (reserveDecimals - baseDecimals));
        }
    }

    // Пример маршрута для создания левереджированной длинной позиции по ETH
    function createLeveragedLongPosition(uint256 iterations) external onlyOwner {
        // я вывел эти эпрувы из цикла чтобы сэкономить газ, в образовательных целях - норм
        IERC20(usdcAddress).approve(address(swapRouter), type(uint256).max);
        IERC20(wethAddress).approve(address(lendingPool), type(uint256).max);

        uint256 totalBorrowed = 0;
        uint256 totalCollateralAdded = 0;

        for (uint256 i = 0; i < iterations; i++) {
            uint256 maxUsdcBorrow = getMaxBorrowAmount(usdcAddress);
            uint256 safeUsdcBorrow = (maxUsdcBorrow * 75) / 100; // Use 75% for safety

            require(safeUsdcBorrow > 0, "borrowAmount is not greater than 0");
            lendingPool.borrow(usdcAddress, safeUsdcBorrow, 2, 0, address(this));

            // Меняем стейблкоины на ETH
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: usdcAddress,
                tokenOut: wethAddress,
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp + 15,
                amountIn: safeUsdcBorrow,
                amountOutMinimum: (safeUsdcBorrow * 990) / 1000, // В реальном сценарии вы должны установить минимальное значение
                sqrtPriceLimitX96: 0
            });

            uint256 ethReceived = swapRouter.exactInputSingle(params);
            totalCollateralAdded += ethReceived;

            // Депонируем ETH обратно в протокол
            lendingPool.supply(wethAddress, ethReceived, address(this), 0);

            (,,,,, uint256 healthFactor) = lendingPool.getUserAccountData(address(this));
            if (healthFactor < 1.1e18) break;
        }
        console.log("Total USDC borrowed:", totalBorrowed / 1e6);
        console.log("Total ETH added as collateral:", totalCollateralAdded / 1e18);

        // Получаем финальные данные
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,, uint256 healthFactor) =
            lendingPool.getUserAccountData(address(this));

        console.log(
            "Final leverage ratio: x", (totalCollateralBase * 1e18) / (totalCollateralBase - totalDebtBase) / 1e18
        );
        console.log("Final health factor:", healthFactor / 1e18);
    }

    // Функция для создания левереджированной позиции с использованием флеш-кредита
    function createLeveragedPositionWithFlashLoan(uint256 flashLoanAmount) external onlyOwner {
        address[] memory assets = new address[](1);
        assets[0] = usdcAddress;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        uint256[] memory modes = new uint256[](1);
        modes[0] = 0; // 0 = отсутствие долга, 1 = стабильная ставка, 2 = переменная ставка

        lendingPool.flashLoan(address(this), assets, amounts, modes, address(this), abi.encode(flashLoanAmount), 0);
    }

    // Эта функция вызывается протоколом AAVE после получения флеш-кредита
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address,
        bytes calldata
    ) external override returns (bool) {
        require(msg.sender == address(lendingPool), "Callback only from lending pool");

        uint256 borrowAmount = amounts[0];
        uint256 fee = premiums[0];
        uint256 totalToRepay = borrowAmount + fee;

        // Обмениваем USDC на ETH
        IERC20(assets[0]).approve(address(swapRouter), borrowAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: assets[0],
            tokenOut: wethAddress,
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: borrowAmount,
            amountOutMinimum: 0, // В реальном сценарии вы должны установить минимальное значение
            sqrtPriceLimitX96: 0
        });

        uint256 ethReceived = swapRouter.exactInputSingle(params);

        // Поставляем ETH в качестве обеспечения
        IERC20(wethAddress).approve(address(lendingPool), ethReceived);
        lendingPool.supply(wethAddress, ethReceived, address(this), 0);

        // Берем максимально возможный заем
        (,, uint256 availableBorrowsBase,,,) = lendingPool.getUserAccountData(address(this));
        uint256 newBorrowAmount = (availableBorrowsBase * 70) / 100; // 70% от доступного

        lendingPool.borrow(assets[0], newBorrowAmount, 2, 0, address(this));

        // Убедимся, что у нас достаточно для погашения флеш-кредита
        require(IERC20(assets[0]).balanceOf(address(this)) >= totalToRepay, "Not enough to repay flash loan");

        // Одобряем возврат флеш-кредита
        IERC20(assets[0]).approve(address(lendingPool), totalToRepay);

        return true;
    }

    function getAccountData()
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return lendingPool.getUserAccountData(address(this));
    }

    function withdraw(address asset, uint256 amount) external onlyOwner {
        lendingPool.withdraw(asset, amount, owner);
    }

    function repay(address asset, uint256 amount) external onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).approve(address(lendingPool), amount);
        lendingPool.repay(asset, amount, 2, address(this));
    }

    function emergencyWithdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner, balance);
    }
}
