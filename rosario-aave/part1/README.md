# Aave V1 from scratch: Part 1 notes

Study notes for Part 1 of the video tutorial "rebuild Aave V1 from scratch" (about 9.5 hours).

Video: https://www.youtube.com/watch?v=k8TRY5lcs8Q

These are notes written from the transcript, not a word-for-word copy. Each section links to the moment in the video where it starts. Code was rebuilt from what the instructor typed. Where the spoken transcript was unclear, it follows the original Aave V1 code. Check the instructor's repo for the exact version.

## Chapters

| # | Chapter | Starts | Notes |
|---|---------|--------|-------|
| 1 | Intro and architecture | [00:00:00](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=0s) | [01-intro.md](01-intro.md) |
| 2 | Project setup | [00:08:42](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=522s) | [02-project-setup.md](02-project-setup.md) |
| 3 | WadRayMath library | [00:12:00](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=720s) | [03-wad-ray-math.md](03-wad-ray-math.md) |
| 4 | LendingPoolCore and CoreLibrary | [01:05:36](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=3936s) | [04-lending-pool-core.md](04-lending-pool-core.md) |
| 5 | Index-based accounting | [01:57:31](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=7051s) | [05-index-based-accounting.md](05-index-based-accounting.md) |
| 6 | Deposit (overview) | [03:14:08](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=11648s) | [06-deposit-overview.md](06-deposit-overview.md) |
| 7 | LendingPool and the deposit flow | [03:15:15](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=11715s) | [07-lending-pool.md](07-lending-pool.md) |
| 8 | AToken | [03:39:52](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=14392s) | [08-atoken.md](08-atoken.md) |
| 9 | Redeem | [06:19:54](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=22794s) | [09-redeem.md](09-redeem.md) |
| 10 | LendingPoolDataProvider | [06:28:40](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=23320s) | [10-lending-pool-data-provider.md](10-lending-pool-data-provider.md) |
| 11 | LTV, liquidation threshold, health factor | [06:46:19](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=24379s) | [11-ltv-liquidation-threshold-health-factor.md](11-ltv-liquidation-threshold-health-factor.md) |

## How the video jumps around

The video doesn't finish one topic before starting the next:

- **Chapter 7 (LendingPool)** starts `deposit()`. To finish it, the video stops to build the AToken in chapter 8. The rest of `deposit()` comes at the end of chapter 8. Notes 07 and 08 follow the video, so 07 points ahead to 08 for the end of `deposit()`.
- **Chapter 9 (Redeem)** lasts about 9 minutes and only lists the steps. The video then builds the data provider and explains health factor, and finishes `redeem()` near the end (about 08:44 to 09:30). **09-redeem.md holds the whole redeem flow in one file**, with timestamps for each part.
- **Chapter 11** is the longest chapter. It explains the risk concepts, then writes most of the data provider code. The code is in **10-lending-pool-data-provider.md**, and the concepts are in **11**.

## Suggested reading order

1. 01 → 08 in order (setup, math, core, indexes, deposit, AToken).
2. **11** (LTV, liquidation threshold, health factor): read it before the data provider.
3. **10** (data provider: health factor code, user totals, `balanceDecreaseAllowed`).
4. **09** (the full redeem flow, which uses everything above).

## Files in the project

```
src/
  libraries/        WadRayMath.sol, CoreLibrary.sol, EthAddressLib.sol
  configuration/    AddressStorage.sol, LendingPoolAddressesProvider.sol
  lendingpool/      LendingPool.sol, LendingPoolCore.sol, LendingPoolDataProvider.sol
  tokenization/     AToken.sol
  interfaces/       IReserveInterestRateStrategy.sol, IPriceOracleGetter.sol
test/unit/...       harnesses + unit tests per contract
test/integration/   LendingPool integration tests (deposit, redeem)
```

Part 1 ends during the redeem integration tests. Borrow, repay, rate swap, liquidation and flash loans are in Part 2.
