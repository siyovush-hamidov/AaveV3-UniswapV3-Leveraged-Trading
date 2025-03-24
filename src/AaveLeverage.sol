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

interface IUniswapV3Router {
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
    IUniswapV3Router public swapRouter;

    address public wethAddress;
    address public usdcAddress;
    uint24 public constant UNISWAP_POOL_FEE = 3000;

    constructor(address _lendingPool, address _dataProvider, address _swapRouter, address _weth, address _usdc) {
        owner = msg.sender;
        lendingPool = IPool(_lendingPool);
        dataProvider = IAaveProtocolDataProvider(_dataProvider);
        swapRouter = IUniswapV3Router(_swapRouter);
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
        lendingPool.supply(asset, amount, address(this), 0);
    }

    function getMaxBorrowAmount(address borrowAsset) public view returns (uint256) {
        // Get available borrow base amount (in USD)
        (,, uint256 availableBorrowsBase,,,) = lendingPool.getUserAccountData(address(this));
        // Get reserve decimals for the asset we want to borrow
        (uint256 reserveDecimals,,,,) = dataProvider.getReserveConfigurationData(borrowAsset);
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
    function openLeveragedPosition(bool isLong) external onlyOwner {
        // Однократно одобряем USDC и WETH для экономии газа
        IERC20(usdcAddress).approve(address(swapRouter), type(uint256).max);
        IERC20(wethAddress).approve(address(lendingPool), type(uint256).max);

        uint256 totalBorrowedUSDC = 0; // Общая сумма заемных средств в USDC
        uint256 totalSuppliedETH = 0; // Общая сумма депонированного ETH
        uint256 totalCollateral = 0;
        uint256 totalDebt = 0;
        uint256 currentHealthFactor = 1;
        uint256 iteration = 1;

        // Получаем начальный health factor
        (,,,,, currentHealthFactor) = lendingPool.getUserAccountData(address(this));

        // Запускаем цикл, пока health factor остается выше 1.0
        while (currentHealthFactor > 1.2e18) {
            console.log("Iteration #", iteration++);

            // Определяем максимально возможную сумму заема в USDC
            uint256 maxBorrowableUSDC = getMaxBorrowAmount(usdcAddress);
            if (maxBorrowableUSDC <= 1) {
                console.log("No more borrowing capacity!");
                break;
            }

            console.log("Borrowing USDC:", maxBorrowableUSDC / 1e6);
            lendingPool.borrow(usdcAddress, maxBorrowableUSDC, 2, 0, address(this));
            totalBorrowedUSDC += maxBorrowableUSDC;
            console.log("Total USDC borrowed:", totalBorrowedUSDC / 1e6);

            // Обмениваем USDC на ETH через Uniswap
            IUniswapV3Router.ExactInputSingleParams memory swapParams = IUniswapV3Router.ExactInputSingleParams({
                tokenIn: usdcAddress,
                tokenOut: wethAddress,
                fee: UNISWAP_POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp + 15,
                amountIn: maxBorrowableUSDC,
                amountOutMinimum: (maxBorrowableUSDC * 990) / 1000, // Учитываем небольшой slippage
                sqrtPriceLimitX96: 0
            });

            uint256 receivedETH = swapRouter.exactInputSingle(swapParams);
            console.log("Received ETH from swap:", receivedETH / 1e18);
            totalSuppliedETH += receivedETH;
            console.log("Total ETH supplied as collateral:", totalSuppliedETH / 1e18);

            // Депонируем полученный ETH обратно в AAVE
            lendingPool.supply(wethAddress, receivedETH, address(this), 0);

            // Обновляем данные аккаунта и проверяем новый health factor
            (totalCollateral, totalDebt,,,, currentHealthFactor) = lendingPool.getUserAccountData(address(this));

            console.log("Updated leverage ratio: x", (totalCollateral * 1e18) / (totalCollateral - totalDebt) / 1e16);
            console.log("Updated health factor:", currentHealthFactor / 1e16, "\n");

            // Останавливаем, если health factor стал ниже 1.0 (близок к ликвидации)
            if (currentHealthFactor < 1e18) break;
        }

        console.log("Final borrowed USDC:", totalBorrowedUSDC);
        console.log("Final supplied ETH:", totalSuppliedETH);

        // Финальный расчет левериджа
        (uint256 finalCollateral, uint256 finalDebt,,,,) = lendingPool.getUserAccountData(address(this));
        console.log("Final leverage ratio: x", (finalCollateral * 1e18) / (finalCollateral - finalDebt));
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

        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: assets[0],
            tokenOut: wethAddress,
            fee: UNISWAP_POOL_FEE,
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
