# 💰 Leverage Trading on Aave V3 with Uniswap V3

This project demonstrates how to use Aave V3 to open leveraged positions on Uniswap V3. Imagine being able to amplify your trading power by borrowing assets directly from Aave!

## ️ What Does It Do?

The program allows you to:

- **Open Long and Short Leveraged Positions:** Multiply your potential profits (or losses) in the market by borrowing assets on Aave and trading them on Uniswap.
- **Utilize Flash Loans:** For those who love speed and efficiency, it's possible to open leveraged positions using flash loans.

## How to Run?

1.  **Install Foundry:**

    ```bash
    curl -L https://foundry.paradigm.xyz | bash
    foundryup
    ```

    This is your magic tool for working with Solidity! ✨

2.  **Clone the Repository:**

    ```bash
    git clone https://github.com/siyovush-hamidov/AaveV3-UniswapV3-Leveraged-Trading
    cd AaveV3-UniswapV3-Leveraged-Trading
    ```

3.  **Update Submodules:**

    ```bash
    git submodule update --init --recursive
    ```

    It's like assembling a team of superheroes for your project!

4.  **Run Anvil:**

    ```bash
    anvil --fork-url https://eth.llamarpc.com
    ```

    This creates a local copy of the Ethereum mainnet where you can test your contract.

5.  **Run the Deployment Script:**

    ```bash
    forge script script/RunLeverage.s.sol:AaveLeverageScript --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
    ```

    This deploys your contract to the local network.

6.  **Run Tests:**

    ```bash
    forge test --match-path test/AaveLeverage.t.sol --rpc-url http://127.0.0.1:8545 --via-ir -vv
    ```

    Make sure everything works as expected! ✅

## ⚠️ Disclaimer

This project is created for educational purposes only. It is not financial advice or a trading recommendation. Use it at your own risk!

## Contribution

Any suggestions and improvements are welcome! Let's make this project even cooler!
