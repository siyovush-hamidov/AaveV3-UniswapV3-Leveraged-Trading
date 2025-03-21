// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
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
    ISwapRouter public swapRouter;
    
    address public wethAddress;
    address public usdcAddress;
    uint24 public constant POOL_FEE = 3000;
    
    constructor(address _lendingPool, address _swapRouter, address _weth, address _usdc) {
        owner = msg.sender;
        lendingPool = IPool(_lendingPool);
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
        lendingPool.supply(asset, amount, address(this), 0);
    }
    
    // Пример маршрута для создания левереджированной длинной позиции по ETH
    function createLeveragedLongPosition(uint256 iterations) external onlyOwner {
        // Получаем данные о счете пользователя
        (,, uint256 availableBorrowsBase,,,) = lendingPool.getUserAccountData(address(this));
        require(availableBorrowsBase > 0, "No available borrows");
        
        for (uint i = 0; i < iterations; i++) {
            // Расчитываем, сколько можно занять (например, 70% от доступного)
            uint256 borrowAmount = (availableBorrowsBase * 70) / 100;
            if (borrowAmount == 0) break;
            
            // Занимаем стейблкоины
            lendingPool.borrow(usdcAddress, borrowAmount, 2, 0, address(this));
            
            // Меняем стейблкоины на ETH
            IERC20(usdcAddress).approve(address(swapRouter), borrowAmount);
            
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: usdcAddress,
                tokenOut: wethAddress,
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp + 15,
                amountIn: borrowAmount,
                amountOutMinimum: 0, // В реальном сценарии вы должны установить минимальное значение
                sqrtPriceLimitX96: 0
            });
            
            uint256 amountOut = swapRouter.exactInputSingle(params);
            
            // Депозируем ETH обратно в протокол
            IERC20(wethAddress).approve(address(lendingPool), amountOut);
            lendingPool.supply(wethAddress, amountOut, address(this), 0);
            
            // Обновляем доступные для займа средства
            (,, availableBorrowsBase,,,) = lendingPool.getUserAccountData(address(this));
        }
    }
    
    // Функция для создания левереджированной позиции с использованием флеш-кредита
    function createLeveragedPositionWithFlashLoan(uint256 flashLoanAmount) external onlyOwner {
        address[] memory assets = new address[](1);
        assets[0] = usdcAddress;
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;
        
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0; // 0 = отсутствие долга, 1 = стабильная ставка, 2 = переменная ставка
        
        lendingPool.flashLoan(
            address(this),
            assets,
            amounts,
            modes,
            address(this),
            abi.encode(flashLoanAmount),
            0
        );
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
    
    function getAccountData() external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    ) {
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