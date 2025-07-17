# Leverage Trading on Aave with Uniswap
This project lets you open leveraged trading positions using Aave and Uniswap.
️
## What Does It Do?
The AaveLeverage contract allows you to:

- Open Long/Short Positions: Go long (WETH collateral, borrow USDC) or short (USDC collateral, borrow WETH) to multiply your market exposure.
- Use Flash Loans: Open or close positions efficiently with Aave flash loans, handling fees dynamically.
- Close Positions: Repay debts and withdraw collateral seamlessly, using flash loans and Uniswap swaps.

## How to Run?

### 1. Clone the Repository:
```
git clone https://github.com/siyovush-hamidov/AaveV3-UniswapV3-Leveraged-Trading
cd AaveV3-UniswapV3-Leveraged-Trading
```

### 2. Update Submodules:
```
git submodule update --init --recursive --progress
```
### 3. Run Anvil:
We will run the test against the mainnet fork at this specific block number `22853637`.
```
anvil --fork-url https://eth.llamarpc.com --fork-block-number 22853637
```
To fork the current state of the mainnet, simply omit `--fork-block-number 22853637`.

**Important Note:** We’re using Llama RPC as an example. If it fails, you can find other RPC endpoints at [Chainlist](chainlist.org/chain/1).

### 4. Run Tests:
After running the Anvil, open a new terminal window to run the tests:
```
forge test --match-path test/AaveLeverage.t.sol --rpc-url http://127.0.0.1:8545 --via-ir -vv
```
**Important Note:** If the tests fail due to errors such as block retrieval issues immediately after starting Anvil, wait a few minutes before running them.

There are 8 tests in `AaveLeverage.t.sol` to qualify the functionality of the AaveLeverage contract:
- Opening Long/Short Positions:
    - Iterative approach:
        - `testIterativeLeverageLong`
        - `testIterativeLeverageShort`
    - Flash loan approach: 
        - `testFlashLoanLeverageLong`
        - `testFlashLoanLeverageShort`
- Position closing tests verify that positions can be closed, repaying debt and withdrawing collateral:
    - `testIterativeLeverageLongAndClose`
    - `testIterativeLeverageShortAndClose`
    - `testFlashLoanLeverageLongAndClose`
    - `testFlashLoanLeverageShortAndClose`

Each test outputs logs describing the position's state. For example, logs for `testFlashLoanLeverageLong` with an initial supply of 5 ETH = $12,585 at $2,517 per ETH (based on mainnet block `22853637`, the same block we forked with Anvil) and target leverage of 3x:
- Total collateral value ($): 37984. **Indicates $37,984 supplied as collateral in AAVE.**
- Total debt amount ($): 25512. **Represents $25,512 in debt.**
- Position health factor (1e18): 1235748382342767286. **Shows the health factor is approximately 1.24, indicating a safe position. It is maximum when the position is closed(e.g. `testFlashLoanLeverageLongAndClose`).**
- Current leverage ratio (1e18): 3045602733416478739. **Reflects a leverage of approximately 3.05x.**
- Available borrow amount ($): 5064. **Indicates $5,064 still available to borrow, as maximum leverage was not targeted.**
- LTV (1e2): 8050. **Represents an LTV of 80.5% for the ETH/USDC trading pair.**
- Final Wallet USDC balance ($): 10000. **If the position is closed, balances may differ from the initial amount due to profits, losses, or fees.**
- Final Wallet WETH balance (1e18): 5000000000000000000. **Represents 5 ETH; similar to USDC, balances may change if the position is closed.**

### 5. Run the deployment script:
```
forge script script/AaveLeverage.s.sol:AaveLeverageScript --rpc-url http://127.0.0.1:8545 --broadcast -vv --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```
This script deploys the `AaveLeverage` contract to your local Anvil instance.

You can create your own script to interact with the contract. Once the contract is deployed, you can create your own custom scripts to interact with it, or you can use command-line tools with Anvil's RPC interface for simpler calls.

**Important Note:** Private key presented here is from Anvil.

## Disclaimer
This project is created for educational purposes only. It is not financial advice or a trading recommendation. Do not use the code in production or with real funds.

## Contribution
Any suggestions and improvements are welcome!