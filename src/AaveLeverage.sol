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
    uint24 private immutable AAVE_FLASH_LOAN_FEE;

    event LeveragedPositionOpened(address indexed opener);
    event LeveragedPositionOpenedWithFlashLoan(address indexed opener);

    error OnlyOwner();
    error InsufficientBalance();
    error InvalidSlippage();
    error InvalidFlashLoanCallback();
    error InvalidFlashLoanInitiator();
    error ZeroFlashLoanBorrowAmount();
    error SwapFailed();
    error ZeroAmountSupplyCollateral();
    error UnsupportedAssetSupplyCollateral();
    error ZeroAssetPrice();
    error ApproveFailed();
    error ExceedingMaxLeverage();

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
            receivedAsset = _swapTokens(borrowAsset, supplyAsset, availableBorrows);
            aaveLendingPool.supply(supplyAsset, receivedAsset, address(this), 0);

            availableBorrows = _getMaxBorrowAmount(borrowAsset);
            (,,,,, healthFactor) = aaveLendingPool.getUserAccountData(address(this));
        }
        emit LeveragedPositionOpened(msg.sender);
    }

    // Проблема:
    // Мы не знаем и не можем знать заранее, сколько надо поставить flashLoanAmount
    // Решение:
    // Используя формулу для рассчёта maxLeverage, программа сама может посчитать flashLoanAmount
    // НО НУЖНЫ:
    // - количество изначального капитала
    // - желаемый уровень плеча

    // Проблема:
    // После флэш лоана, обязательно будет нужно доплачивать со своих денег, чтобы выплатить долг:
    // так быть не должно, то есть рассчёт количества flash loan

    function openLeveragedPositionFlashLoan(
    uint256 intialDeposit,
    uint256 targetLeverage,
    uint256 slippageTolerance
    bool isLong,
) external onlyOwner {
    address asset = isLong ? usdcAddress : wethAddress;
    address supplyAsset = isLong ? wethAddress : usdcAddress;

    // Validate inputs
    if (capitalAmount == 0) revert ZeroAmountSupplyCollateral();
    if (targetLeverage <= 1e18) revert("Leverage must be greater than 1");
    // if (slippageTolerance > 100000) revert InvalidSlippage(); // Max 510% slippage

    // Check max leverage
    uint256 maxLeverage = getMaxLeverage(asset, slippageTolerance);
    if (targetLeverage > maxLeverage) revert ExceedingMaxLeverage();

    // Calculate flash loan amount
    uint256 flashLoanAmount = calculateFlashLoanAmount(asset, capitalAmount, targetLeverage, slippageTolerance);
    if (flashLoanAmount == 0) revert ZeroFlashLoanBorrowAmount();

    // Initiate flash loan
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
    address supplyAsset = isLong ? wethAddress : usdcAddress;

    // Swap flash loaned asset to supply asset
    _approveIfNeeded(asset, address(uniswapRouter));
    uint256 receivedAsset = _swapTokens(asset, supplyAsset, amount);
    if (receivedAsset == 0) revert SwapFailed();

    // Supply swapped asset as collateral
    _approveIfNeeded(supplyAsset, address(aaveLendingPool));
    aaveLendingPool.supply(supplyAsset, receivedAsset, initiator, 0);

    // Borrow to repay flash loan
    uint256 totalToRepay = amount + premium;
    aaveLendingPool.borrow(asset, totalToRepay, 2, 0, initiator);

    // Approve repayment
    if (IERC20(asset).balanceOf(address(this)) < totalToRepay) revert InsufficientBalance();
    _approveIfNeeded(asset, address(aaveLendingPool));

    return true;
}

    function _getMaxBorrowAmount(address borrowAsset) private view returns (uint256) {
        (,, uint256 availableBorrowsBase,,,) = aaveLendingPool.getUserAccountData(address(this));
        (uint256 reserveDecimals,,,,) = aaveDataProvider.getReserveConfigurationData(borrowAsset);
        uint256 assetPrice = uniswapOracle.getAssetPrice(borrowAsset);
        if (assetPrice == 0) revert ZeroAssetPrice();
        uint256 maxBorrow = availableBorrowsBase * (10 ** reserveDecimals) / assetPrice;
        return maxBorrow;
    }

    function _approveIfNeeded(address token, address spender) private {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            if (!IERC20(token).approve(spender, type(uint256).max)) revert ApproveFailed();
        }
    }

    function _swapTokens(address tokenIn, address tokenOut, uint256 amountIn) private returns (uint256) {
        uint256 amountOutMin = uniswapQuoter.quoteExactInputSingle(tokenIn, tokenOut, UNISWAP_POOL_FEE, amountIn, 0);
        if (amountOutMin == 0) revert InvalidSlippage();
        uint256 amountOut = uniswapRouter.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: UNISWAP_POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp + 5,
                amountIn: amountIn,
                amountOutMinimum: (amountOutMin * 9900) / 10000,
                sqrtPriceLimitX96: 0
            })
        );
        if (amountOut == 0) revert SwapFailed();
        return amountOut;
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

    function getMaxLeverageFlashLoan(address asset, uint256 slippageTolerance) public view returns (uint256) {
    // Get LTV from Aave Data Provider
    (uint256 ltv,,,,) = aaveDataProvider.getReserveConfigurationData(asset);
    // LTV is in basis points (e.g., 8000 for 80%), convert to decimal
    uint256 ltvDecimal = ltv * 1e14; // Convert to 1e18 for precision (8000 -> 0.8 * 1e18)

    // Fees in basis points
    uint256 uniswapFee = uint256(UNISWAP_POOL_FEE); // e.g., 3000 for 0.3%
    uint256 flashLoanFee = uint256(AAVE_FLASH_LOAN_FEE); // e.g., 500 for 0.05%
    uint256 slippage = slippageTolerance; // User-defined, e.g., 10000 for 1%

    // Calculate fee adjustment: (1 - (Fu + Fs)) / (1 + Ff)
    uint256 feeNumerator = 1e18 - ((uniswapFee + slippage) * 1e14); // 1 - (Fu + Fs) in 1e18 precision
    uint256 feeDenominator = 1e18 + (flashLoanFee * 1e14); // 1 + Ff in 1e18 precision
    uint256 feeAdjustment = (feeNumerator * 1e18) / feeDenominator; // (1 - (Fu + Fs)) / (1 + Ff)

    // Calculate max leverage: 1 / (1 - LTV * feeAdjustment)
    uint256 denominator = 1e18 - ((ltvDecimal * feeAdjustment) / 1e18);
    if (denominator == 0) revert("Invalid leverage calculation");
    uint256 maxLeverage = (1e18 * 1e18) / denominator; // Leverage in 1e18 precision

    return maxLeverage;
}

function calculateFlashLoanAmount(
    address asset,
    uint256 capitalAmount,
    uint256 targetLeverage,
    uint256 slippageTolerance
) public view returns (uint256) {
    // Validate inputs
    if (capitalAmount == 0) revert ZeroAmountSupplyCollateral();
    if (targetLeverage <= 1e18) revert("Leverage must be greater than 1");
    // if (slippageTolerance > 100000) revert InvalidSlippage(); // Max 10% slippage

    // Get LTV from Aave Data Provider
    (uint256 ltv,,,,) = aaveDataProvider.getReserveConfigurationData(asset);
    uint256 ltvDecimal = ltv * 1e14; // Convert to 1e18 precision (e.g., 8000 -> 0.8 * 1e18)

    // Fees in basis points
    uint256 uniswapFee = uint256(UNISWAP_POOL_FEE); // e.g., 3000 for 0.3%
    uint256 flashLoanFee = uint256(AAVE_FLASH_LOAN_FEE); // e.g., 500 for 0.05%
    uint256 slippage = slippageTolerance; // User-defined, e.g., 10000 for 1%
    uint256 U = uniswapFee + slippage; // Total swap fee (e and slippage
    uint256 A = flashLoanFee; // Aave flash loan fee

    // Calculate F = D * (L - 1) / (1 - U - L * (1 - U - 1 - A))
    uint256 numerator = (targetLeverage - 1e18) * capitalAmount; // (L - 1) * D
    uint256 denominator = (1e18 - ((U * 1e14) + (targetLeverage * ((1e18 - (U * 1e14)) - (1e18 + (A * 1e14)))) / 1e18));
    if (denominator == 0) revert("Invalid leverage calculation");

    uint256 flashLoanAmount = (numerator * 1e18) / denominator;

    // Adjust for token decimals
    (,,, uint256 reserveDecimals,) = aaveDataProvider.getReserveConfigurationData(asset);
    flashLoanAmount = (flashLoanAmount * (10 ** reserveDecimals)) / 1e18;

    return flashLoanAmount;
}
}
