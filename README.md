# 💰 Leverage Trading on Aave with Uniswap
This project lets you open leveraged trading positions using Aave and Uniswap.
️
## What Does It Do?
The AaveLeverage contract allows you to:
 
- Go long (WETH collateral, borrow USDC) or short (USDC collateral, borrow WETH) to multiply your market exposure.
- Use Flash Loans: Open or close positions efficiently with Aave flash loans, handling fees dynamically.
- Close Positions: Repay debts and withdraw collateral seamlessly, using flash loans and Uniswap swaps.

## How to Run?

Clone the Repository:
```
git clone https://github.com/siyovush-hamidov/AaveV3-UniswapV3-Leveraged-Trading
cd AaveV3-UniswapV3-Leveraged-Trading
```

Update Submodules:
```
git submodule update --init --recursive --progress
```
Run Anvil:
```
anvil --fork-url https://eth.llamarpc.com
```
Find available RPC endpoints at chainlist.org/chain/1; we’re using Llama as an example.
Run Tests:
```
forge test --match-path test/AaveLeverage.t.sol --rpc-url http://127.0.0.1:8545 --via-ir -vv
```

**Important Note:** If tests fail due to errors like block retrival right after starting Anvil, wait a few minutes before running them.

Run the deployment script:
```
forge script script/AaveLeverage.s.sol:AaveLeverageScript --rpc-url http://127.0.0.1:8545 --broadcast -vv --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```
**Important Note:** Private key presented here is from anvil. Your crypto thieving dreams stay dreams :)

## ⚠️ Disclaimer
This project is created for educational purposes only. It is not financial advice or a trading recommendation.

## Contribution
Any suggestions and improvements are welcome!