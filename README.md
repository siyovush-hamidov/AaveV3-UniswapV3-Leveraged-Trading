# AAVE Leverage Strategy

This project demonstrates how to create leveraged positions using AAVE lending protocol through both manual iteration and flash loans.

## Key Components

1. **AaveLeverage.sol**: Main contract implementing leveraged position strategies
2. **Tests**: Demonstration of the leverage mechanisms in action

## Setup Instructions

1. Clone the repository
2. Install Foundry if you haven't already: [https://book.getfoundry.sh/getting-started/installation](https://book.getfoundry.sh/getting-started/installation)
3. Install dependencies:
`forge install`
## Running Tests

To run the tests on a local fork of mainnet:
`forge test -vv`
Use `-vvv` for more verbose output.

## Leverage Concepts

The code demonstrates two methods for creating leveraged positions:

1. **Manual Iterative Leverage**: Deposit collateral, borrow, swap, deposit again, repeat.
2. **Flash Loan Leverage**: Use a flash loan to create leverage in a single transaction.

## Maximum Leverage Calculation

For an asset with LTV (Loan-to-Value) ratio of L (expressed as a decimal):

Maximum theoretical leverage = 1/(1-L)

For example, with LTV of 0.7 (70%):
Maximum leverage = 1/(1-0.7) = 3.33x

In practice, a safety margin should be applied to avoid liquidation.