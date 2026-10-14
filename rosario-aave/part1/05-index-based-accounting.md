# 5. Index-based accounting

▶ [Watch from 01:57:31](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=7051s) · Previous: [04](04-lending-pool-core.md) · Next: [06 Deposit](06-deposit-overview.md)

This is the key idea of Aave and the hardest part of the video, so take your time on it.

## The problem

Updating every user's balance every second, or even every block, would need a loop over all users. That costs far too much gas.

## The solution: one global index plus one checkpoint per user

Aave stores:
- **one global index per reserve**, which grows over time, and
- **one checkpoint per user**: the index value when that user's balance was last updated.

Any balance or debt is then:

> **currentValue = storedValue × currentIndex / userIndex**

`currentIndex / userIndex` is exactly the interest earned since the user's last update. Nothing has to be stored per second.

## Worked example: deposit (linear interest)

Alice deposits 100 DAI when the reserve's **liquidity index = 1.05**, so her checkpoint is 1.05. The deposit rate is 5% a year.

Plain math: 100 × (1 + 0.05 × 1) = **105 DAI** after one year.

Aave's way:
1. After one year the reserve index becomes `1.05 × (1 + 0.05 × 1) = 1.1025`.
2. Alice's balance = `100 × 1.1025 / 1.05` = **105 DAI**. Same answer.

## Worked example: variable borrow (compound interest)

Alice borrows 100 DAI when the **variable borrow index = 1.05**, so her checkpoint is 1.05. The rate is 5% for 2 years.

Plain math: 100 × (1.05)² = **110.25 DAI**.

Aave's way:
1. Reserve index → `1.05 × (1.05)² = 1.157625`.
2. Debt = `100 × 1.157625 / 1.05` = **110.25 DAI**. Same answer.

Depositors **earn** interest (linear, through the liquidity index). Variable borrowers **pay** interest (compound, through the variable borrow index).

## `updateCumulativeIndexes` ([≈02:12:36](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=7956s))

Moves both reserve indexes forward to now:

```solidity
function updateCumulativeIndexes(ReserveData storage self) internal {
    uint256 totalBorrows = getTotalBorrows(self);

    // No borrows → nobody pays interest → indexes stay the same.
    if (totalBorrows > 0) {
        // newLiquidityIndex = oldIndex × (1 + liquidityRate × yearsElapsed)
        uint256 cumulatedLiquidityInterest =
            calculateLinearInterest(self.currentLiquidityRate, self.lastUpdateTimestamp);
        self.lastLiquidityCumulativeIndex = cumulatedLiquidityInterest.rayMul(self.lastLiquidityCumulativeIndex);

        // newVariableBorrowIndex = oldIndex × (1 + variableRate / SECONDS_PER_YEAR) ^ secondsElapsed
        uint256 cumulatedVariableBorrowInterest =
            calculateCompoundedInterest(self.currentVariableBorrowRate, self.lastUpdateTimestamp);
        self.lastVariableBorrowCumulativeIndex =
            cumulatedVariableBorrowInterest.rayMul(self.lastVariableBorrowCumulativeIndex);
    }
}

function getTotalBorrows(ReserveData storage reserve) internal view returns (uint256) {
    return reserve.totalBorrowsStable + reserve.totalBorrowsVariable;
}
```

Borrowers pay the depositors, so if there are no borrows the indexes don't move.

This function doesn't change `lastUpdateTimestamp`. `_updateReserveInterestRatesAndTimestamp` does that, in [07](07-lending-pool.md).

### Tests
- No borrows → both indexes unchanged.
- With borrows, 1 year → liquidity index = linear × 1, variable index = compound × 1 ≈ 1.105 at 10%.
- Variable index starts at **1.20**, 10%, 1 year → ≈ **1.326** (compounds on top of 1.20). Liquidity index stays at 1.
- Liquidity index starts at **1.20**, 5%, 1 year → **1.26**. Variable index unchanged.

## `getNormalizedIncome`: the same calculation without saving it ([≈02:31:31](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=9091s))

```solidity
// current normalized income = linearInterest × lastLiquidityCumulativeIndex
function getNormalizedIncome(CoreLibrary.ReserveData storage reserve) internal view returns (uint256) {
    uint256 cumulated = calculateLinearInterest(reserve.currentLiquidityRate, reserve.lastUpdateTimestamp)
        .rayMul(reserve.lastLiquidityCumulativeIndex);
    return cumulated;
}
```

It does the same math as the liquidity half of `updateCumulativeIndexes`, but it's a `view`. It returns the **up-to-date** liquidity index without writing it. The AToken uses it to show live balances.

Tests: no time passed → 1 ray; one year at 5% → 1.05; starting index 1.10 → 1.10 × 1.05.

## Recap

- currentValue = stored × currentIndex / userIndex.
- Deposits use linear interest through the liquidity index. Variable debt uses compound interest through the variable borrow index.
- `updateCumulativeIndexes` saves the new indexes. `getNormalizedIncome` only calculates them.
