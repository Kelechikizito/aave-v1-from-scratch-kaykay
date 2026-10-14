# 5. Swap rate mode, rebalance stable rate, flash loan

Previous: [04 Liquidation manager](04-liquidation-manager.md) · [Back to index](README.md)

The video covers each of these in under a minute and doesn't write their code. It says what each one does and points to the integration tests in the instructor's repo (`LendingPoolIntegrationTest`). Lines marked **(Aave V1)** come from the original Aave V1 design, not from the video.

## Swap borrow rate mode ([07:09:03](https://www.youtube.com/watch?v=aq2cMmibayI&t=25743s))

Moves an existing loan **from stable to variable or back**. It's called on the LendingPool.

- **(Aave V1)** `swapBorrowRateMode(address reserve)`. Switching to stable has to pass the same stable rules as borrowing: stable enabled, the collateral isn't mostly the same asset, and the loan isn't too large ([01 Borrow](01-borrow.md), section "Stable-rate rules").
- It works with the same core helper as borrow: take the principal plus interest out of the old bucket and put it in the new one (`_updateReserveTotalBorrowsByRateMode`). Then the user's `stableBorrowRate` or variable index is set as in `_updateUserStateOnBorrow`.

## Rebalance stable borrow rate ([07:09:44](https://www.youtube.com/watch?v=aq2cMmibayI&t=25784s))

Resets an existing **stable** loan's rate when it has drifted too far from market conditions and is now unfair to the reserve or the borrower.

- Example from the video: a user's stable borrow rate has dropped **below the deposit (liquidity) rate**, so the protocol would pay depositors more than that borrower pays.
- It's called through `LendingPool.rebalanceStableBorrowRate(...)`.
- **(Aave V1)** Anyone can call it for any user. The user's rate is moved up to the current stable rate when it's below the liquidity rate, and moved down when it's well above the current stable rate.

## Flash loan ([07:10:56](https://www.youtube.com/watch?v=aq2cMmibayI&t=25856s))

Borrow **any amount the reserve holds, with no collateral**, as long as you **return it plus a fee in the same transaction**. Otherwise the whole transaction reverts, so the protocol can't lose the funds.

- The LendingPool sends the funds, calls your contract back, then checks it got the money plus the fee back.
- Common uses: arbitrage, collateral swaps, self-liquidation. The instructor notes that many DeFi exploits have used flash loans to get large amounts of capital.
- **(Aave V1)** `flashLoan(address receiver, address reserve, uint256 amount, bytes params)`. The receiver implements `executeOperation(reserve, amount, fee, params)` and must send `amount + fee` back to the core before it returns. The pool compares the core's balance before and after. The fee (0.35% in V1) is split between depositors and the protocol.

## Outro ([07:12:14](https://www.youtube.com/watch?v=aq2cMmibayI&t=25934s))

End of the series. The integration tests in the instructor's repo are the best place to look next, especially for the three features above.
