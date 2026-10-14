# 1. Intro and architecture

▶ [Watch from 00:00:00](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=0s) · Next: [02 Project setup](02-project-setup.md)

## Goal

Rebuild Aave V1 with modern Solidity, and write unit and integration tests to see how each piece works. The main operations covered across the series:

- deposit
- redeem (withdraw)
- borrow
- repay
- rate swap (stable ↔ variable)
- liquidation
- flash loan

New terms (loan to value, liquidation threshold, health factor…) are explained as they come up. The instructor recommends their separate "Aave explained" video for a high-level overview first. It's optional.

## What changes compared to the original Aave V1 repo

| Original (2020) | This rebuild | Why |
|---|---|---|
| Truffle + Solidity 0.5 | Foundry + Solidity 0.8.30 | Modern tooling |
| Upgradeable contracts (proxies) | Plain, non-upgradeable contracts | Out of scope; keeps the code simpler |
| `SafeMath` | Plain `+ - * /` | 0.8 checks for overflow and underflow on its own |
| `require(cond, "msg")` | `if (!cond) revert Custom__Error();` | Cheaper gas, clearer errors |
| aToken interest redirection | **Not implemented** | Removed in later Aave versions; adds complexity |
| Aave's own test suite | Own unit + integration tests | Built for understanding, not full coverage |

The original Aave tests are worth reading because they test the protocol as a whole. Here the goal is to understand each flow and function one at a time.

## Architecture

```
            ┌──────────────────────────────────────────────┐
  user ───► │ LendingPool  (entry point for every action)  │
            │ deposit · redeem* · borrow · repay ·         │
            │ swap rate · flash loan · liquidation         │
            └──────┬──────────────┬──────────────┬─────────┘
                   │              │              │ delegatecall
                   ▼              ▼              ▼
         LendingPoolCore     AToken (aDAI…)   LendingPoolLiquidationManager
         (accounting +       (deposit receipt,
          holds the funds)    earns interest)
                   ▲
                   │ reads
         LendingPoolDataProvider ──► PriceOracle
         (health factor, user totals)

  InterestRateStrategy   → calculates deposit / stable / variable rates
  LendingPoolConfigurator → sets up and configures reserves
  LendingPoolAddressesProvider → registry of every contract's address
```
\* Redeem is the exception: the user calls the **AToken**, not the LendingPool. See [09](09-redeem.md).

### What each contract does

- **LendingPool**: the entry point. Users call it for every action.
- **LendingPoolCore**: the accounting. It stores the state of each reserve (indexes, rates, totals) and each user's data per reserve. It also **holds the deposited tokens**.
- **AToken**: an ERC20 receipt (aDAI, aUSDC…) minted when a user deposits. Its balance grows with interest. Burning it returns the underlying asset plus interest.
- **LendingPoolDataProvider**: reads the core and the price oracle and combines them into higher-level numbers, such as the health factor.
- **LendingPoolLiquidationManager**: handles liquidations. The LendingPool forwards liquidation calls to it with `delegatecall`.
- **Interest rate strategy**: calculates the deposit rate and the stable and variable borrow rates.
- **LendingPoolConfigurator**: admin contract that sets up and configures reserves.

A **reserve** is one asset's market (DAI, USDC, WETH…).
