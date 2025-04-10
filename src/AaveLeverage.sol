// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "forge-std/Test.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
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
    function getAddressesProvider() external view returns (ILendingPoolAddressesProvider);
    function setUserEMode(uint8 categoryId) external;
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

interface IUniswapV3Oracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface ILendingPoolAddressesProvider {
    function getPriceOracle() external view returns (address);
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

interface IUniswapV3Quoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}

contract AaveLeverage is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address private immutable owner;
    IAavePool private immutable aaveLendingPool;
    IAaveProtocolDataProvider private immutable aaveDataProvider;
    IUniswapV3Router private immutable uniswapRouter;
    IUniswapV3Quoter private immutable uniswapQuoter;
    IUniswapV3Oracle private immutable uniswapOracle;
    address private immutable wethAddress;
    address private immutable usdcAddress;
    uint24 private immutable UNISWAP_POOL_FEE;

    event LeveragedPositionOpened(address indexed opener);
    event LeveragedPositionOpenedWithFlashLoan(address indexed opener);

    error OnlyOwner();
    error InsufficientAllowance();
    error InsufficientBalance();
    error InvalidSlippage();
    error InvalidFlashLoanCallback();
    error InvalidFlashLoanInitiator();
    error ZeroFlashLoanBorrowAmount();
    error SwapFailed();
    error HealthFactorTooLow();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(
        address _aaveLendingPool,
        address _aaveDataProvider,
        address _addressProvider,
        address _uniswapRouter,
        address _uniswapQuoter,
        uint24 _UNISWAP_POOL_FEE,
        address _weth,
        address _usdc
    ) {
        owner = msg.sender;
        aaveLendingPool = IAavePool(_aaveLendingPool);
        aaveDataProvider = IAaveProtocolDataProvider(_aaveDataProvider);
        uniswapRouter = IUniswapV3Router(_uniswapRouter);
        uniswapQuoter = IUniswapV3Quoter(_uniswapQuoter);
        uniswapOracle = IUniswapV3Oracle(ILendingPoolAddressesProvider(_addressProvider).getPriceOracle());
        wethAddress = _weth;
        usdcAddress = _usdc;
        UNISWAP_POOL_FEE = _UNISWAP_POOL_FEE;
        aaveLendingPool.setUserEMode(0); // имеет смысл использовать, если токены одной категории. К примеру: стейблкойны
    }

    function supplyCollateral(address asset, uint256 amount) external onlyOwner {
        require(amount > 0, "Amount provided must be greater than 0!");
        require(asset == wethAddress || asset == usdcAddress, "Unsupported asset!");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _approveIfNeeded(asset, address(aaveLendingPool));
        aaveLendingPool.supply(asset, amount, address(this), 0);
    }

    function openLeveragedPosition(bool isLong, uint256 minHealthFactor) external onlyOwner {
        address borrowAsset = isLong ? usdcAddress : wethAddress;
        address supplyAsset = isLong ? wethAddress : usdcAddress;
        _approveIfNeeded(borrowAsset, address(uniswapRouter));
        _approveIfNeeded(supplyAsset, address(aaveLendingPool));
        uint256 availableBorrows;
        (,,,,, uint256 currentHealthFactor) = aaveLendingPool.getUserAccountData(address(this));
        while (
            (
                (availableBorrows = _getMaxBorrowAmount(borrowAsset))
                    > (isLong ? 1 : _getMinSwapAmount(borrowAsset, supplyAsset))
            ) // do the loop until there is enough amount of tokens for swapping
                && currentHealthFactor > minHealthFactor // and the desired healthFactor is maintained
        ) {
            aaveLendingPool.borrow(borrowAsset, availableBorrows, 2, 0, address(this));
            uint256 receivedAsset = _swapTokens(borrowAsset, supplyAsset, availableBorrows);
            aaveLendingPool.supply(supplyAsset, receivedAsset, address(this), 0);
            (,,,,, currentHealthFactor) = aaveLendingPool.getUserAccountData(address(this)); // keeping track of healtFactor
        }
        emit LeveragedPositionOpened(msg.sender);
    }

    function openLeveragedPositionFlashLoan(uint256 flashLoanAmount, bool isLong) external onlyOwner {
        if (flashLoanAmount == 0) revert ZeroFlashLoanBorrowAmount();
        address asset = isLong ? usdcAddress : wethAddress;
        aaveLendingPool.flashLoanSimple(address(this), asset, flashLoanAmount, abi.encode(isLong), 0);
        emit LeveragedPositionOpenedWithFlashLoan(msg.sender);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata paramsData
    ) external nonReentrant returns (bool) {
        if (msg.sender != address(aaveLendingPool)) revert InvalidFlashLoanCallback();
        if (initiator != address(this)) revert InvalidFlashLoanInitiator();
        if (amount == 0) revert ZeroFlashLoanBorrowAmount();

        (bool isLong) = abi.decode(paramsData, (bool));
        uint256 totalToRepay = amount + premium; // premium is the fee for the flash loan

        _approveIfNeeded(asset, address(uniswapRouter));
        uint256 receivedAssetFromUniswap = _swapTokens(asset, isLong ? wethAddress : usdcAddress, amount); // swaps borrowAmount of asset to opposite token
        if (receivedAssetFromUniswap == 0) revert SwapFailed();

        aaveLendingPool.supply(isLong ? wethAddress : usdcAddress, receivedAssetFromUniswap, initiator, 0);
        aaveLendingPool.borrow(asset, totalToRepay, 2, 0, initiator);

        if (IERC20(asset).balanceOf(initiator) < totalToRepay) revert InsufficientBalance();
        _approveIfNeeded(asset, address(aaveLendingPool)); // approving aaveLendingPool to take out our money for repayment of the flash loan

        return true;
    }

    function _getMaxBorrowAmount(address borrowAsset) private view returns (uint256) {
        (,, uint256 availableBorrowsBase,,,) = aaveLendingPool.getUserAccountData(address(this));
        (uint256 reserveDecimals,,,,) = aaveDataProvider.getReserveConfigurationData(borrowAsset);
        uint256 assetPrice = uniswapOracle.getAssetPrice(borrowAsset);
        require(assetPrice > 0, "Asset price is zero! Zero division will occur!");
        uint256 maxBorrow = availableBorrowsBase * (10 ** reserveDecimals) / assetPrice;
        return maxBorrow;
    }

    function _approveIfNeeded(address token, address spender) private {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            bool success = IERC20(token).approve(spender, type(uint256).max);
            require(success, "Failed to approve!");
        }
    }

    function _swapTokens(address tokenIn, address tokenOut, uint256 amountIn) private returns (uint256) {
        uint256 amountOutMin = uniswapQuoter.quoteExactInputSingle(tokenIn, tokenOut, UNISWAP_POOL_FEE, amountIn, 0);
        if (amountOutMin == 0) revert InvalidSlippage();
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: UNISWAP_POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp + 5,
            amountIn: amountIn,
            amountOutMinimum: (amountOutMin * 9800) / 10000,
            sqrtPriceLimitX96: 0
        });
        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        require(amountOut > 0, "Failed to swap!");
        return amountOut;
    }

    // TODO : CHANGE TO NORMAL _getMinSwapAmount USING IUniswapV3Pool.slot0 AND sqrtPriceX96
    function _getMinSwapAmount(address tokenIn, address tokenOut) private returns (uint256) {
        uint256 minAmount = 2e8;
        uint256 estimatedOutput = uniswapQuoter.quoteExactInputSingle(tokenIn, tokenOut, UNISWAP_POOL_FEE, minAmount, 0);
        while (estimatedOutput == 0) {
            minAmount *= 2;
            estimatedOutput = uniswapQuoter.quoteExactInputSingle(tokenIn, tokenOut, UNISWAP_POOL_FEE, minAmount, 0);
        }
        return minAmount;
    }

    function getAccountData()
        public
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
        return aaveLendingPool.getUserAccountData(address(this));
    }
}
