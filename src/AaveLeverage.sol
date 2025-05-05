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
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
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
}

interface IAaveProtocolDataProvider {
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
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

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

interface IUniswapV3Quoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);

    function quoteExactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountIn);
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
    uint24 private immutable AAVE_FLASH_LOAN_FEE;
    uint24 private constant SWAP_DEADLINE_DELTA = 5 seconds;

    event LeveragedPositionOpened(address indexed opener);
    event LeveragedPositionOpenedWithFlashLoan(address indexed opener);
    event PositionClosed(address indexed closer, address asset, uint256 amountWithdrawn);
    event Approval(address indexed token, address indexed spender, uint256 amount);

    error OnlyOwner();
    error InsufficientBalance();
    error InvalidAmountOutMin();
    error InvalidFlashLoanCallback();
    error InvalidFlashLoanInitiator();
    error ZeroFlashLoanBorrowAmount();
    error SwapFailed();
    error ZeroAmountSupplyCollateral();
    error UnsupportedAssetSupplyCollateral();
    error ZeroAssetPrice();
    error ApproveFailed();
    error NoDebtToRepay();
    error InsufficientCollateral();

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
        uint24 _AAVE_FLASH_LOAN_FEE,
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
        AAVE_FLASH_LOAN_FEE = _AAVE_FLASH_LOAN_FEE;
    }

    function supplyCollateral(address asset, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmountSupplyCollateral();
        if (asset != wethAddress && asset != usdcAddress) revert UnsupportedAssetSupplyCollateral();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _approveIfNeeded(asset, address(aaveLendingPool));
        aaveLendingPool.supply(asset, amount, address(this), 0);
    }

    function openLeveragedPosition(bool isLong, uint256 minHealthFactor) external onlyOwner {
        address borrowAsset = isLong ? usdcAddress : wethAddress;
        address supplyAsset = isLong ? wethAddress : usdcAddress;

        _approveIfNeeded(borrowAsset, address(uniswapRouter));
        _approveIfNeeded(supplyAsset, address(aaveLendingPool));

        uint256 receivedAsset;
        uint256 availableBorrows = _getMaxBorrowAmount(borrowAsset);
        uint256 minBorrowUSDC = 1e6;
        uint256 minBorrowWETH = 1e15;
        (,,,,, uint256 healthFactor) = aaveLendingPool.getUserAccountData(address(this));

        // Loop until health factor drops below min or borrow amount becomes too small to matter
        while (healthFactor > minHealthFactor && availableBorrows > (isLong ? minBorrowUSDC : minBorrowWETH)) {
            aaveLendingPool.borrow(borrowAsset, availableBorrows, 2, 0, address(this));
            receivedAsset = _swapExactInputSingle(borrowAsset, supplyAsset, availableBorrows);
            aaveLendingPool.supply(supplyAsset, receivedAsset, address(this), 0);
            availableBorrows = _getMaxBorrowAmount(borrowAsset);
            (,,,,, healthFactor) = aaveLendingPool.getUserAccountData(address(this));
        }
        emit LeveragedPositionOpened(msg.sender);
    }

    function openLeveragedPositionFlashLoan(
        uint256 initialDeposit,
        uint256 targetLeverage,
        uint24 slippageTolerance,
        bool isLong
    ) external onlyOwner {
        if (initialDeposit == 0) revert ZeroAmountSupplyCollateral();
        address asset = isLong ? usdcAddress : wethAddress;
        address supplyAsset = isLong ? wethAddress : usdcAddress;
        uint256 flashLoanAmount =
            _calculateFlashLoanAmount(asset, supplyAsset, initialDeposit, targetLeverage, slippageTolerance);

        aaveLendingPool.flashLoanSimple(address(this), asset, flashLoanAmount, abi.encode(isLong, false), 0);
        emit LeveragedPositionOpenedWithFlashLoan(msg.sender);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata paramsData
    ) external returns (bool) {
        if (msg.sender != address(aaveLendingPool)) revert InvalidFlashLoanCallback();
        if (initiator != address(this)) revert InvalidFlashLoanInitiator();
        if (amount == 0) revert ZeroFlashLoanBorrowAmount();

        (bool isLong, bool isClosing) = abi.decode(paramsData, (bool, bool));
        uint256 totalToRepay = amount + premium;
        address collateralAsset = isLong ? wethAddress : usdcAddress;

        _approveIfNeeded(asset, address(aaveLendingPool));
        _approveIfNeeded(asset, address(uniswapRouter));
        _approveIfNeeded(collateralAsset, address(uniswapRouter));

        if (isClosing) {
            aaveLendingPool.repay(asset, amount, 2, address(this));
            aaveLendingPool.withdraw(collateralAsset, type(uint256).max, address(this));

            uint256 assetBalance = IERC20(asset).balanceOf(address(this));
            if (assetBalance < totalToRepay) {
                uint256 receivedAssetFromUniswap =
                    _swapExactOutputSingle(collateralAsset, asset, totalToRepay - assetBalance);
                if (receivedAssetFromUniswap == 0) revert SwapFailed();
            }
        } else {
            uint256 receivedAssetFromUniswap = _swapExactInputSingle(asset, isLong ? wethAddress : usdcAddress, amount);
            if (receivedAssetFromUniswap == 0) revert SwapFailed();

            aaveLendingPool.supply(isLong ? wethAddress : usdcAddress, receivedAssetFromUniswap, initiator, 0);
            aaveLendingPool.borrow(asset, totalToRepay, 2, 0, initiator);
        }

        if (IERC20(asset).balanceOf(address(this)) < totalToRepay) {
            revert InsufficientBalance();
        }

        return true;
    }

    function closePosition(bool isLong) external onlyOwner nonReentrant {
        address debtAsset = isLong ? usdcAddress : wethAddress;
        address collateralAsset = isLong ? wethAddress : usdcAddress;

        (, uint256 totalDebtBase,,,,) = aaveLendingPool.getUserAccountData(address(this));
        if (totalDebtBase == 0) revert NoDebtToRepay();
        aaveLendingPool.flashLoanSimple(address(this), debtAsset, totalDebtBase, abi.encode(isLong, true), 0);

        uint256 finalDebtAssetBalance = IERC20(debtAsset).balanceOf(address(this));
        uint256 finalCollateralAssetBalance = IERC20(collateralAsset).balanceOf(address(this));

        if (finalDebtAssetBalance > 0) {
            IERC20(debtAsset).safeTransfer(owner, finalDebtAssetBalance);
        }
        if (finalCollateralAssetBalance > 0) {
            IERC20(collateralAsset).safeTransfer(owner, finalCollateralAssetBalance);
        }

        emit PositionClosed(msg.sender, collateralAsset, finalCollateralAssetBalance);
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

    function _getMaxBorrowAmount(address borrowAsset) private view returns (uint256) {
        (,, uint256 availableBorrowsBase,,,) = aaveLendingPool.getUserAccountData(address(this));
        (uint256 reserveDecimals,,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(borrowAsset);
        uint256 assetPrice = uniswapOracle.getAssetPrice(borrowAsset);
        if (assetPrice == 0) revert ZeroAssetPrice();
        uint256 maxBorrow = availableBorrowsBase * (10 ** reserveDecimals) / assetPrice;
        return maxBorrow;
    }

    function _approveIfNeeded(address token, address spender) private {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (allowance == 0) {
            bool success = IERC20(token).approve(spender, type(uint256).max);
            if (!success) revert ApproveFailed();
            emit Approval(token, spender, type(uint256).max);
        }
    }

    function _swapExactInputSingle(address tokenIn, address tokenOut, uint256 amountIn) private returns (uint256) {
        uint256 amountOutMin = uniswapQuoter.quoteExactInputSingle(tokenIn, tokenOut, UNISWAP_POOL_FEE, amountIn, 0);
        if (amountOutMin == 0) revert InvalidAmountOutMin();
        uint256 amountOut = uniswapRouter.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: UNISWAP_POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp + SWAP_DEADLINE_DELTA,
                amountIn: amountIn,
                amountOutMinimum: (amountOutMin * 9900) / 10000,
                sqrtPriceLimitX96: 0
            })
        );
        if (amountOut == 0) revert SwapFailed();
        return amountOut;
    }

    function _swapExactOutputSingle(address tokenIn, address tokenOut, uint256 amountOut) private returns (uint256) {
        uint256 amountInMaximum =
            uniswapQuoter.quoteExactOutputSingle(tokenIn, tokenOut, UNISWAP_POOL_FEE, amountOut, 0);
        if (amountInMaximum == 0) revert("Zero input maximum"); // TODO Здесь тоже
        if (amountOut == 0) revert("Zero output amount"); // TODO НУЖНО УБРАТЬ ТЕКСТ
        _approveIfNeeded(tokenIn, address(uniswapRouter));
        uint256 amountIn = uniswapRouter.exactOutputSingle(
            IUniswapV3Router.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: UNISWAP_POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp + SWAP_DEADLINE_DELTA,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum,
                sqrtPriceLimitX96: 0
            })
        );
        if (amountIn == 0) revert SwapFailed();
        return amountIn;
    }

    function _calculateFlashLoanAmount(
        address asset,
        address supplyAsset,
        uint256 initialDeposit,
        uint256 targetLeverage,
        uint256 slippageTolerance
    ) private view returns (uint256) {
        if (initialDeposit == 0) revert ZeroAmountSupplyCollateral();
        if (targetLeverage <= 1e18) revert("Leverage must be greater than 1");

        (uint256 assetDecimals,,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(asset);
        (uint256 supplyAssetDecimals,,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(supplyAsset);

        uint256 assetPrice = uniswapOracle.getAssetPrice(asset);
        uint256 supplyAssetPrice = uniswapOracle.getAssetPrice(supplyAsset);

        uint256 U = (uint256(UNISWAP_POOL_FEE) + slippageTolerance) * 1e12;
        uint256 A = uint256(AAVE_FLASH_LOAN_FEE) * 1e12;

        uint256 initialDepositInUSD = (initialDeposit * supplyAssetPrice) / (10 ** supplyAssetDecimals);
        uint256 numerator = initialDepositInUSD * (targetLeverage - 1e18 + U) / 1e18;
        uint256 denominator = 1e18 - U - A;

        uint256 flashLoanAmountInUSD = (numerator * 1e18) / denominator;
        uint256 flashLoanAmount = (flashLoanAmountInUSD * (10 ** assetDecimals)) / assetPrice;

        if (flashLoanAmount == 0) revert ZeroFlashLoanBorrowAmount();
        return flashLoanAmount;
    }
}
