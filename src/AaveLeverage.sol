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

/// @title AaveLeverage
/// @notice Contract for leveraged trading using Aave and Uniswap V3
/// @dev Implements leveraged trading strategies using Aave's lending pool and Uniswap V3 for swaps
contract AaveLeverage {
    using SafeERC20 for IERC20;

    /// @notice The owner of the contract, set to the deployer
    address private immutable owner;

    /// @notice Aave lending pool interface
    IAavePool private immutable aaveLendingPool;

    /// @notice Aave protocol data provider interface
    IAaveProtocolDataProvider private immutable aaveDataProvider;

    /// @notice Uniswap V3 router interface for swaps
    IUniswapV3Router private immutable uniswapRouter;

    /// @notice Uniswap V3 quoter interface for estimating swap amounts
    IUniswapV3Quoter private immutable uniswapQuoter;

    /// @notice Uniswap V3 oracle interface for asset prices
    IUniswapV3Oracle private immutable uniswapOracle;

    /// @notice Address of the WETH token
    address private immutable wethAddress;

    /// @notice Address of the USDC token
    address private immutable usdcAddress;

    /// @notice Fee tier for Uniswap V3 pool (e.g., 3000 for 0.3%)
    uint24 private immutable UNISWAP_POOL_FEE;

    /// @notice Aave flash loan fee
    uint128 private immutable AAVE_FLASH_LOAN_FEE;

    /// @notice Delta in seconds added to block.timestamp for swap deadlines
    uint24 private immutable SWAP_DEADLINE_DELTA = 5;

    /// @notice Emitted when a leveraged position is opened iteratively
    /// @param opener The address that opened the position
    event LeveragedPositionOpenedIteratively(address indexed opener);

    /// @notice Emitted when a leveraged position is opened using flash loans
    /// @param opener The address that opened the position
    event LeveragedPositionOpenedWithFlashLoan(address indexed opener);

    /// @notice Emitted when a position is closed
    /// @param closer The address that closed the position
    /// @param asset The asset withdrawn
    /// @param amountWithdrawn The amount of asset withdrawn
    event PositionClosed(
        address indexed closer,
        address asset,
        uint256 amountWithdrawn
    );

    /// @notice Error thrown when a non-owner tries to call an owner-only function
    error OnlyOwner();

    /// @notice Error thrown when there is insufficient balance for an operation
    error InsufficientBalance();

    /// @notice Error thrown when the flash loan callback is invalid
    error InvalidFlashLoanCallback();

    /// @notice Error thrown when the flash loan initiator is invalid
    error InvalidFlashLoanInitiator();

    /// @notice Error thrown when the flash loan borrow amount is zero
    error ZeroFlashLoanBorrowAmount();

    /// @notice Error thrown when a swap fails
    error SwapFailed();

    /// @notice Error thrown when supplying zero collateral
    error ZeroAmountSupplyCollateral();

    /// @notice Error thrown when supplying an unsupported asset
    error UnsupportedAssetSupplyCollateral();

    /// @notice Error thrown when the asset price is zero
    error ZeroAssetPrice();

    /// @notice Error thrown when there is no debt to repay
    error NoDebtToRepay();

    /// @notice Error thrown when the target leverage is invalid (lesser than 1, otherwise there is no sense)
    error InvalidTargetLeverage();

    /// @notice Modifier to restrict access to the owner
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// ================================================================
    /// |                     Initialization                           |
    /// ================================================================

    /// @notice Constructor to initialize the contract
    /// @param _aaveLendingPool Address of the Aave lending pool
    /// @param _aaveDataProvider Address of the Aave protocol data provider
    /// @param _addressProvider Address of the Aave lending pool addresses provider
    /// @param _uniswapRouter Address of the Uniswap V3 router
    /// @param _uniswapQuoter Address of the Uniswap V3 quoter
    /// @param _UNISWAP_POOL_FEE Fee tier for Uniswap V3 pool
    /// @param _weth Address of the WETH token
    /// @param _usdc Address of the USDC token
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
        uniswapOracle = IUniswapV3Oracle(
            ILendingPoolAddressesProvider(_addressProvider).getPriceOracle()
        );
        wethAddress = _weth;
        usdcAddress = _usdc;
        UNISWAP_POOL_FEE = _UNISWAP_POOL_FEE;
        AAVE_FLASH_LOAN_FEE = aaveLendingPool.FLASHLOAN_PREMIUM_TOTAL();
    }

    /// ================================================================
    /// |                     Trading Mechanics                        |
    /// ================================================================

    /// @notice Opens a leveraged position iteratively
    /// @param minHealthFactor The minimum health factor to maintain
    /// @param slippageTolerance Slippage tolerance for swaps
    /// @param isLong Whether the position is long or short
    function openLeveragedPosition(
        uint256 minHealthFactor,
        uint24 slippageTolerance,
        bool isLong
    ) external onlyOwner {
        address debtAsset = isLong ? usdcAddress : wethAddress;
        address collateralAsset = isLong ? wethAddress : usdcAddress;

        uint256 minBorrowUSDC = 1e6; // 1 USDC
        uint256 minBorrowWETH = 1e15; // 0.001 WETH
        uint256 availableBorrows = _getMaxBorrowAmount(debtAsset);
        uint256 minBorrowThreshold = isLong ? minBorrowUSDC : minBorrowWETH;
        uint256 swappedAmount;
        (, , , , , uint256 healthFactor) = aaveLendingPool.getUserAccountData(
            address(this)
        );

        IERC20(debtAsset).approve(address(uniswapRouter), type(uint256).max);
        while (
            healthFactor > minHealthFactor &&
            availableBorrows > minBorrowThreshold
        ) {
            aaveLendingPool.borrow(
                debtAsset,
                availableBorrows,
                2, // AAVE's interestRateMode. Should always be passed a value of 2 (variable rate mode)
                0, // AAVE's referralCode. Referral supply is currently inactive in AAVE, you can pass 0.
                address(this)
            );
            swappedAmount = _swapExactInputSingle(
                debtAsset,
                collateralAsset,
                availableBorrows,
                slippageTolerance
            );
            aaveLendingPool.supply(
                collateralAsset,
                swappedAmount,
                address(this),
                0
            );

            availableBorrows = _getMaxBorrowAmount(debtAsset);
            (, , , , , healthFactor) = aaveLendingPool.getUserAccountData(
                address(this)
            );
        }
        emit LeveragedPositionOpenedIteratively(msg.sender);
    }

    /// @notice Opens a leveraged position using flash loans
    /// @param initialDeposit The initial deposit amount
    /// @param targetLeverage The target leverage to achieve
    /// @param slippageTolerance Slippage tolerance for swaps
    /// @param isLong Whether the position is long or short
    function openLeveragedPositionFlashLoan(
        uint256 initialDeposit,
        uint256 targetLeverage,
        uint24 slippageTolerance,
        bool isLong
    ) external onlyOwner {
        if (initialDeposit == 0) revert ZeroAmountSupplyCollateral();
        address debtAsset = isLong ? usdcAddress : wethAddress;
        address collateralAsset = isLong ? wethAddress : usdcAddress;
        bool isOpening = true;

        uint256 flashLoanAmount = _calculateFlashLoanAmount(
            debtAsset,
            collateralAsset,
            initialDeposit,
            targetLeverage,
            slippageTolerance
        );

        aaveLendingPool.flashLoanSimple(
            address(this),
            debtAsset,
            flashLoanAmount,
            abi.encode(isLong, isOpening, slippageTolerance),
            0
        );

        emit LeveragedPositionOpenedWithFlashLoan(msg.sender);
    }

    /// @notice Closes a leveraged position
    /// @param slippageTolerance Slippage tolerance for swaps
    /// @param isLong Whether the position is long or short
    function closePosition(
        uint24 slippageTolerance,
        bool isLong
    ) external onlyOwner {
        address debtAsset = isLong ? usdcAddress : wethAddress;
        address collateralAsset = isLong ? wethAddress : usdcAddress;
        (, uint256 totalDebtBase, , , , ) = aaveLendingPool.getUserAccountData(
            address(this)
        );
        if (totalDebtBase == 0) revert NoDebtToRepay();
        bool isOpening = false;

        uint256 flashLoanAmount = _convertBaseToAsset(debtAsset, totalDebtBase);
        aaveLendingPool.flashLoanSimple(
            address(this),
            debtAsset,
            flashLoanAmount,
            abi.encode(isLong, isOpening, slippageTolerance),
            0
        );

        if (IERC20(debtAsset).balanceOf(address(this)) > 0) {
            IERC20(debtAsset).safeTransfer(
                owner,
                IERC20(debtAsset).balanceOf(address(this))
            );
        }
        if (IERC20(collateralAsset).balanceOf(address(this)) > 0) {
            IERC20(collateralAsset).safeTransfer(
                owner,
                IERC20(collateralAsset).balanceOf(address(this))
            );
        }

        emit PositionClosed(
            msg.sender,
            collateralAsset,
            IERC20(collateralAsset).balanceOf(address(this))
        );
    }

    /// @notice Executes the flash loan operation
    /// @param debtAsset The asset borrowed in the flash loan
    /// @param amount The amount borrowed
    /// @param premium The premium to be paid for the flash loan
    /// @param initiator The initiator of the flash loan
    /// @param paramsData Encoded parameters for the operation
    /// @return True if the operation was successful
    function executeOperation(
        address debtAsset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata paramsData
    ) external returns (bool) {
        if (msg.sender != address(aaveLendingPool))
            revert InvalidFlashLoanCallback();
        if (initiator != address(this)) revert InvalidFlashLoanInitiator();
        if (amount == 0) revert ZeroFlashLoanBorrowAmount();
        (bool isLong, bool isOpening, uint24 slippageTolerance) = abi.decode(
            paramsData,
            (bool, bool, uint24)
        );
        address collateralAsset = isLong ? wethAddress : usdcAddress;
        IERC20(debtAsset).approve(address(aaveLendingPool), type(uint256).max);
        uint256 totalToRepay = amount + premium;

        if (isOpening) {
            IERC20(debtAsset).approve(address(uniswapRouter), amount);
            uint256 receivedAssetFromUniswap = _swapExactInputSingle(
                debtAsset,
                collateralAsset,
                amount,
                slippageTolerance
            );
            aaveLendingPool.supply(
                collateralAsset,
                receivedAssetFromUniswap,
                initiator,
                0
            );
            aaveLendingPool.borrow(debtAsset, totalToRepay, 2, 0, initiator);
        } else {
            aaveLendingPool.repay(
                debtAsset,
                type(uint256).max,
                2,
                address(this)
            );
            aaveLendingPool.withdraw(
                collateralAsset,
                type(uint256).max,
                address(this)
            );
            uint256 assetBalance = IERC20(debtAsset).balanceOf(address(this));
            if (assetBalance < totalToRepay) {
                IERC20(collateralAsset).approve(
                    address(uniswapRouter),
                    type(uint256).max
                );
                _swapExactOutputSingle(
                    collateralAsset,
                    debtAsset,
                    totalToRepay - assetBalance,
                    slippageTolerance
                );
            }
        }
        if (IERC20(debtAsset).balanceOf(address(this)) < totalToRepay) {
            revert InsufficientBalance();
        }
        return true;
    }

    /// ================================================================
    /// |               Functions For External Interactions            |
    /// ================================================================

    /// @notice Supplies collateral to the contract
    /// @param asset The asset to supply
    /// @param amount The amount to supply
    function supplyCollateral(
        address asset,
        uint256 amount
    ) external onlyOwner {
        if (amount == 0) revert ZeroAmountSupplyCollateral();
        if (asset != wethAddress && asset != usdcAddress)
            revert UnsupportedAssetSupplyCollateral();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).approve(address(aaveLendingPool), type(uint256).max);
        aaveLendingPool.supply(asset, amount, address(this), 0);
    }

    /// @notice Retrieves the account data from Aave
    /// @return totalCollateralBase Total collateral in base currency
    /// @return totalDebtBase Total debt in base currency
    /// @return availableBorrowsBase Available borrows in base currency
    /// @return currentLiquidationThreshold Current liquidation threshold
    /// @return ltv Loan-to-value ratio
    /// @return healthFactor Health factor of the position
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
        return aaveLendingPool.getUserAccountData(address(this));
    }

    /// ================================================================
    /// |                     Auxiliary Functions                      |
    /// ================================================================

    /// @notice Calculates the maximum borrow amount for an asset of the user
    /// @param borrowAsset The asset to borrow
    /// @return The maximum borrow amount
    function _getMaxBorrowAmount(
        address borrowAsset
    ) private view returns (uint256) {
        (, , uint256 availableBorrowsBase, , , ) = aaveLendingPool
            .getUserAccountData(address(this));
        (uint256 reserveDecimals, , , , , , , , , ) = aaveDataProvider
            .getReserveConfigurationData(borrowAsset);
        uint256 assetPrice = uniswapOracle.getAssetPrice(borrowAsset);
        if (assetPrice == 0) revert ZeroAssetPrice();
        uint256 maxBorrow = (availableBorrowsBase * (10 ** reserveDecimals)) /
            assetPrice;
        return maxBorrow;
    }

    /// @notice Performs a swap with exact input on Uniswap
    /// @param tokenIn The input token
    /// @param tokenOut The output token
    /// @param amountIn The amount of input token
    /// @param slippageTolerance Slippage tolerance for the swap
    /// @return The amount of output token received
    function _swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 slippageTolerance
    ) private returns (uint256) {
        uint256 amountOutMin = uniswapQuoter.quoteExactInputSingle(
            tokenIn,
            tokenOut,
            UNISWAP_POOL_FEE,
            amountIn,
            0
        );
        uint256 amountOut = uniswapRouter.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: UNISWAP_POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp + SWAP_DEADLINE_DELTA,
                amountIn: amountIn,
                amountOutMinimum: (amountOutMin *
                    (1000000 - slippageTolerance)) / 1000000,
                sqrtPriceLimitX96: 0
            })
        );
        if (amountOut == 0) revert SwapFailed();
        return amountOut;
    }

    /// @notice Performs a swap with exact output on Uniswap
    /// @param tokenIn The input token
    /// @param tokenOut The output token
    /// @param amountOut The desired output amount
    /// @param slippageTolerance Slippage tolerance for the swap
    /// @return The amount of input token used
    function _swapExactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 slippageTolerance
    ) private returns (uint256) {
        uint256 amountInMax = uniswapQuoter.quoteExactOutputSingle(
            tokenIn,
            tokenOut,
            UNISWAP_POOL_FEE,
            amountOut,
            0
        );
        uint256 amountIn = uniswapRouter.exactOutputSingle(
            IUniswapV3Router.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: UNISWAP_POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp + SWAP_DEADLINE_DELTA,
                amountOut: amountOut,
                amountInMaximum: (amountInMax * (1000000 + slippageTolerance)) /
                    1000000,
                sqrtPriceLimitX96: 0
            })
        );
        if (amountIn == 0) revert SwapFailed();
        return amountIn;
    }

    /// @notice Calculates the flash loan amount for opening a position needed to achieve the targetLeverage
    /// @param asset The asset to borrow
    /// @param supplyAsset The asset to supply
    /// @param initialDeposit The initial deposit amount
    /// @param targetLeverage The target leverage
    /// @param slippageTolerance Slippage tolerance
    /// @return The calculated flash loan amount
    function _calculateFlashLoanAmount(
        address asset,
        address supplyAsset,
        uint256 initialDeposit,
        uint256 targetLeverage,
        uint256 slippageTolerance
    ) private view returns (uint256) {
        if (initialDeposit == 0) revert ZeroAmountSupplyCollateral();
        if (targetLeverage <= 1e18) revert InvalidTargetLeverage();

        (uint256 assetDecimals, , , , , , , , , ) = aaveDataProvider
            .getReserveConfigurationData(asset);
        (uint256 supplyAssetDecimals, , , , , , , , , ) = aaveDataProvider
            .getReserveConfigurationData(supplyAsset);

        uint256 assetPrice = uniswapOracle.getAssetPrice(asset);
        uint256 supplyAssetPrice = uniswapOracle.getAssetPrice(supplyAsset);

        uint256 U = (uint256(UNISWAP_POOL_FEE) + slippageTolerance) * 1e12;
        uint256 initialDepositInUSD = (initialDeposit * supplyAssetPrice) /
            (10 ** supplyAssetDecimals);

        uint256 numerator = (initialDepositInUSD * (targetLeverage - 1e18)) /
            1e18;
        uint256 denominator = 1e18 - U;

        uint256 flashLoanAmountInUSD = (numerator * 1e18) / denominator;
        uint256 flashLoanAmount = (flashLoanAmountInUSD *
            (10 ** assetDecimals)) / assetPrice;

        if (flashLoanAmount == 0) revert ZeroFlashLoanBorrowAmount();
        return flashLoanAmount;
    }

    /// @notice Converts an amount from AAVE's base currency to asset units
    /// @param asset The asset to convert to
    /// @param amountBase The amount in base currency
    /// @return The amount in asset units
    function _convertBaseToAsset(
        address asset,
        uint256 amountBase
    ) private view returns (uint256) {
        (uint256 reserveDecimals, , , , , , , , , ) = aaveDataProvider
            .getReserveConfigurationData(asset);
        uint256 slippage = 1e9;
        uint256 assetPrice = uniswapOracle.getAssetPrice(asset);
        if (assetPrice == 0) revert ZeroAssetPrice();
        uint256 flashLoanAmount = (amountBase * (10 ** reserveDecimals)) /
            assetPrice;
        return flashLoanAmount + (flashLoanAmount / slippage);
    }
}
