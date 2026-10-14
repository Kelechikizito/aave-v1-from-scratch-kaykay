# Aave V1 from scratch: Part 2 notes

Study notes for Part 2 of the video tutorial (about 7 hours 12 minutes). It continues [Part 1](../part1/README.md).

Video: https://www.youtube.com/watch?v=aq2cMmibayI

These are notes written from the transcript, not a word-for-word copy. Each section links to the moment in the video where it starts. Code was rebuilt from what the instructor typed. Where the spoken transcript was unclear, it follows the original Aave V1 code. Check the instructor's repo for the exact version.

## Chapters

| # | Chapter | Starts | Notes |
|---|---------|--------|-------|
| 1 | Borrow | [00:00:00](https://www.youtube.com/watch?v=aq2cMmibayI&t=0s) | [01-borrow.md](01-borrow.md) |
| 2 | Repay | [03:08:52](https://www.youtube.com/watch?v=aq2cMmibayI&t=11332s) | [02-repay.md](02-repay.md) |
| 3 | Liquidation (overview + LendingPool entry point) | [04:28:47](https://www.youtube.com/watch?v=aq2cMmibayI&t=16127s) | [03-liquidation.md](03-liquidation.md) |
| 4 | LendingPoolLiquidationManager | [04:44:53](https://www.youtube.com/watch?v=aq2cMmibayI&t=17093s) | [04-liquidation-manager.md](04-liquidation-manager.md) |
| 5 | Swap borrow rate mode | [07:09:03](https://www.youtube.com/watch?v=aq2cMmibayI&t=25743s) | [05-swap-rebalance-flashloan.md](05-swap-rebalance-flashloan.md) |
| 6 | Rebalance stable borrow rate | [07:09:44](https://www.youtube.com/watch?v=aq2cMmibayI&t=25784s) | same file |
| 7 | Flash loan | [07:10:56](https://www.youtube.com/watch?v=aq2cMmibayI&t=25856s) | same file |
| 8 | Outro | [07:12:14](https://www.youtube.com/watch?v=aq2cMmibayI&t=25934s) | (no notes) |

## How the video jumps around

- **Liquidation.** `LendingPool.liquidationCall` is started in chapter 3, but the video finishes its `delegatecall` and error decoding only at the end of chapter 4 (≈06:54). **03-liquidation.md has the whole entry point.** 04 covers what the manager does internally, including the new AToken and core functions it needs.
- **Swap, rebalance, flash loan.** Each gets less than a minute in the video and no code is written. The notes say what each does and point to the tests in the instructor's repo. Anything taken from the original Aave V1 code, not from the video, is labelled.

## Suggested reading order

01 → 02 → 03 → 04 → 05. Borrow builds the core functions (`get user borrow balances`, `increase/decrease total borrows`…) that repay and liquidation reuse.

## Concepts from Part 1 you'll need

- Index-based accounting: currentValue = stored × currentIndex / userIndex ([Part 1 · 05](../part1/05-index-based-accounting.md)).
- Health factor, LTV, liquidation threshold ([Part 1 · 11](../part1/11-ltv-liquidation-threshold-health-factor.md)).
- `calculateUserGlobalData`, `getCompoundedBorrowBalance` ([Part 1 · 10](../part1/10-lending-pool-data-provider.md)).
- `_updateReserveInterestRatesAndTimestamp(reserve, liquidityAdded, liquidityTaken)` ([Part 1 · 07](../part1/07-lending-pool.md)).
