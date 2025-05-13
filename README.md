# 💰 Leverage Trading on Aave with Uniswap
This project lets you open leveraged trading positions using Aave and Uniswap. Amplify your trades by borrowing assets and swapping them in one go.
️
## What Does It Do?
The AaveLeverage contract allows you to:

Open Long/Short Positions: Go long (WETH collateral, borrow USDC) or short (USDC collateral, borrow WETH) to multiply your market exposure.
Use Flash Loans: Open or close positions efficiently with Aave flash loans, handling fees dynamically.
Close Positions: Repay debts and withdraw collateral seamlessly, using flash loans and Uniswap swaps.

Perfect for exploring DeFi leverage and flash loans!

## How to Run?

Install Foundry:
```
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Clone the Repository:
```
git clone https://github.com/siyovush-hamidov/AaveV3-UniswapV3-Leveraged-Trading
cd AaveV3-UniswapV3-Leveraged-Trading
```

Update Submodules:
```
git submodule update --init --recursive
```
Run Anvil:
```
anvil --fork-url https://eth.llamarpc.com
```
Run Tests:
```
forge test --match-path test/AaveLeverage.t.sol --rpc-url http://127.0.0.1:8545 --via-ir -vv
```

Run the deployment script:
```
forge script script/RunLeverage.s.sol:AaveLeverageScript --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
```

⚠️ Disclaimer
This project is created for educational purposes only. It is not financial advice or a trading recommendation. Use it at your own risk!
Contribution
Any suggestions and improvements are welcome! Let's make this project even cooler!
