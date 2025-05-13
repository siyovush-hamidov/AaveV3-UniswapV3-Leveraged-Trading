// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IAaveProtocolDataProvider.sol";
import "./interfaces/IUniswapV3Oracle.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";
import "./interfaces/IFlashLoanReceiver.sol";
import "./interfaces/IUniswapV3Router.sol";
import "./interfaces/IUniswapV3Quoter.sol";

contract AaveLeverage {
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
    uint128 private immutable AAVE_FLASH_LOAN_FEE;
    uint24 private immutable SWAP_DEADLINE_DELTA = 5;

    event LeveragedPositionOpened(address indexed opener);
    event LeveragedPositionOpenedWithFlashLoan(address indexed opener);
    event PositionClosed(address indexed closer, address asset, uint256 amountWithdrawn);
    event Approval(address indexed token, address indexed spender, uint256 amount);

    error OnlyOwner();
    error InsufficientBalance();
    error InvalidFlashLoanCallback();
    error InvalidFlashLoanInitiator();
    error ZeroFlashLoanBorrowAmount();
    error SwapFailed();
    error ZeroAmountSupplyCollateral();
    error UnsupportedAssetSupplyCollateral();
    error ZeroAssetPrice();
    error NoDebtToRepay();
    error InsufficientCollateral();
    error InvalidTargetLeverage();
    error InvalidUniswapFee();

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
        AAVE_FLASH_LOAN_FEE = aaveLendingPool.FLASHLOAN_PREMIUM_TOTAL();
    }

    function openLeveragedPosition(uint256 minHealthFactor, uint24 slippageTolerance, bool isLong) external onlyOwner {
        address debtAsset = isLong ? usdcAddress : wethAddress;
        address collateralAsset = isLong ? wethAddress : usdcAddress;

        uint256 minBorrowUSDC = 1e6;
        uint256 minBorrowWETH = 1e15;
        uint256 availableBorrows = _getMaxBorrowAmount(debtAsset);
        uint256 minBorrowThreshold = isLong ? minBorrowUSDC : minBorrowWETH;
        uint256 swappedAmount;
        (,,,,, uint256 healthFactor) = aaveLendingPool.getUserAccountData(address(this));
        
        IERC20(debtAsset).approve(address(uniswapRouter), type(uint256).max);
        while (healthFactor > minHealthFactor && availableBorrows > minBorrowThreshold) {
            aaveLendingPool.borrow(debtAsset, availableBorrows, 2, 0, address(this));
            swappedAmount = _swapExactInputSingle(debtAsset, collateralAsset, availableBorrows, slippageTolerance);
            aaveLendingPool.supply(collateralAsset, swappedAmount, address(this), 0);
  
            availableBorrows = _getMaxBorrowAmount(debtAsset);
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
        address debtAsset = isLong ? usdcAddress : wethAddress;
        address collateralAsset = isLong ? wethAddress : usdcAddress;
        
        uint256 flashLoanAmount =
            _calculateFlashLoanAmount(debtAsset, collateralAsset, initialDeposit, targetLeverage, slippageTolerance);
        
        aaveLendingPool.flashLoanSimple(
            address(this), debtAsset, flashLoanAmount, abi.encode(isLong, false, slippageTolerance), 0
        );
        
        emit LeveragedPositionOpenedWithFlashLoan(msg.sender);
    }

    function closePosition(uint24 slippageTolerance, bool isLong) external onlyOwner {
        address debtAsset = isLong ? usdcAddress : wethAddress;
        address collateralAsset = isLong ? wethAddress : usdcAddress;
        (, uint256 totalDebtBase,,,,) = aaveLendingPool.getUserAccountData(address(this));
        if (totalDebtBase == 0) revert NoDebtToRepay();
        
        uint256 flashLoanAmount = _convertBaseToAsset(debtAsset, totalDebtBase);
        aaveLendingPool.flashLoanSimple(
            address(this), debtAsset, flashLoanAmount, abi.encode(isLong, true, slippageTolerance), 0
        );
        
        if (IERC20(debtAsset).balanceOf(address(this)) > 0) {
            IERC20(debtAsset).safeTransfer(owner, IERC20(debtAsset).balanceOf(address(this)));
        }
        if (IERC20(collateralAsset).balanceOf(address(this)) > 0) {
            IERC20(collateralAsset).safeTransfer(owner, IERC20(collateralAsset).balanceOf(address(this)));
        }

        emit PositionClosed(msg.sender, collateralAsset, IERC20(collateralAsset).balanceOf(address(this)));
    }

    function executeOperation(
        address debtAsset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata paramsData
    ) external returns (bool) {
        if (msg.sender != address(aaveLendingPool)) revert InvalidFlashLoanCallback();
        if (initiator != address(this)) revert InvalidFlashLoanInitiator();
        if (amount == 0) revert ZeroFlashLoanBorrowAmount();
        (bool isLong, bool isClosing, uint24 slippageTolerance) = abi.decode(paramsData, (bool, bool, uint24));
        address collateralAsset = isLong ? wethAddress : usdcAddress;
        IERC20(debtAsset).approve(address(aaveLendingPool), type(uint256).max);
        uint256 totalToRepay = amount + premium;
        
        if (!isClosing) {
            IERC20(debtAsset).approve(address(uniswapRouter), amount);
            uint256 receivedAssetFromUniswap =
                _swapExactInputSingle(debtAsset, collateralAsset, amount, slippageTolerance);
            aaveLendingPool.supply(collateralAsset, receivedAssetFromUniswap, initiator, 0);
            aaveLendingPool.borrow(debtAsset, totalToRepay, 2, 0, initiator);
        } else {
            aaveLendingPool.repay(debtAsset, type(uint256).max, 2, address(this));
            aaveLendingPool.withdraw(collateralAsset, type(uint256).max, address(this));
            uint256 assetBalance = IERC20(debtAsset).balanceOf(address(this));
            if (assetBalance < totalToRepay) {
                IERC20(collateralAsset).approve(address(uniswapRouter), type(uint256).max);
                _swapExactOutputSingle(collateralAsset, debtAsset, totalToRepay - assetBalance, slippageTolerance);
            }
        }
        if (IERC20(debtAsset).balanceOf(address(this)) < totalToRepay) {
            revert InsufficientBalance();
        }
        return true;
    }

    function supplyCollateral(address asset, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmountSupplyCollateral();
        if (asset != wethAddress && asset != usdcAddress) revert UnsupportedAssetSupplyCollateral();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).approve(address(aaveLendingPool), type(uint256).max);
        aaveLendingPool.supply(asset, amount, address(this), 0);
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

    function _swapExactInputSingle(address tokenIn, address tokenOut, uint256 amountIn, uint24 slippageTolerance)
        private
        returns (uint256)
    {
        uint256 amountOutMin = uniswapQuoter.quoteExactInputSingle(tokenIn, tokenOut, UNISWAP_POOL_FEE, amountIn, 0);
        uint256 amountOut = uniswapRouter.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: UNISWAP_POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp + SWAP_DEADLINE_DELTA,
                amountIn: amountIn,
                amountOutMinimum: amountOutMin * (1000000 - slippageTolerance) / 1000000,
                sqrtPriceLimitX96: 0
            })
        );
        if (amountOut == 0) revert SwapFailed();
        return amountOut;
    }

    function _swapExactOutputSingle(address tokenIn, address tokenOut, uint256 amountOut, uint256 slippageTolerance)
        private
        returns (uint256)
    {
        uint256 amountInMax = uniswapQuoter.quoteExactOutputSingle(tokenIn, tokenOut, UNISWAP_POOL_FEE, amountOut, 0);
        uint256 amountIn = uniswapRouter.exactOutputSingle(
            IUniswapV3Router.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: UNISWAP_POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp + SWAP_DEADLINE_DELTA,
                amountOut: amountOut,
                amountInMaximum: amountInMax * (1000000 + slippageTolerance) / 1000000,
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
        if (targetLeverage <= 1e18) revert InvalidTargetLeverage();

        (uint256 assetDecimals,,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(asset);
        (uint256 supplyAssetDecimals,,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(supplyAsset);

        uint256 assetPrice = uniswapOracle.getAssetPrice(asset);
        uint256 supplyAssetPrice = uniswapOracle.getAssetPrice(supplyAsset);

        uint256 U = (uint256(UNISWAP_POOL_FEE) + slippageTolerance) * 1e12;
        uint256 A = uint256(AAVE_FLASH_LOAN_FEE * 100) * 1e12;

        uint256 initialDepositInUSD = (initialDeposit * supplyAssetPrice) / (10 ** supplyAssetDecimals);
        uint256 numerator = initialDepositInUSD * (targetLeverage - 1e18 + U) / 1e18;
        uint256 denominator = 1e18 - U - A;

        uint256 flashLoanAmountInUSD = (numerator * 1e18) / denominator;
        uint256 flashLoanAmount = (flashLoanAmountInUSD * (10 ** assetDecimals)) / assetPrice;

        if (flashLoanAmount == 0) revert ZeroFlashLoanBorrowAmount();
        return flashLoanAmount;
    }

    function _convertBaseToAsset(address asset, uint256 amountBase) private view returns (uint256) {
        (uint256 reserveDecimals,,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(asset);
        uint256 slippage = 1e9;
        uint256 assetPrice = uniswapOracle.getAssetPrice(asset);
        if (assetPrice == 0) revert ZeroAssetPrice();
        uint256 flashLoanAmount = (amountBase * (10 ** reserveDecimals)) / assetPrice;
        return flashLoanAmount + (flashLoanAmount / slippage);
    }
}
