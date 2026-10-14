# 3. Liquidation: overview and the LendingPool entry point

▶ [Watch from 04:28:47](https://www.youtube.com/watch?v=aq2cMmibayI&t=16127s) · Previous: [02 Repay](02-repay.md) · Next: [04 Liquidation manager](04-liquidation-manager.md)

## What liquidation is

When a borrower's **health factor < 1**, a third party (the **liquidator**) can:
- repay **part** of the borrower's debt in one reserve, and
- receive the borrower's collateral from another reserve, worth the repayment **plus a bonus**.

Afterwards the borrower has **less debt and less collateral**. If any of the chosen collateral is left, it can also pay off the borrower's outstanding origination fee.

**Close factor (V1):** a liquidator can repay at most **50%** of the debt in one call. Later Aave versions changed this.

**Liquidation bonus:** a reserve setting such as 105, meaning the liquidator gets 5% extra collateral. That's the incentive to liquidate.

### Worked example

Borrower owes 0.02 WETH and has 100 DAI of collateral. DAI = 0.00025 ETH. DAI bonus = 105.

1. The liquidator asks to repay 0.02 WETH, which is capped to 50% = **0.01 WETH**.
2. In DAI: 0.01 / 0.00025 = **40 DAI**.
3. Plus the bonus: 40 × 105 / 100 = **42 DAI** to the liquidator (40 + 5% of 40).
4. If the borrower doesn't have that much of the chosen collateral, the repayment shrinks to match (see [04](04-liquidation-manager.md)).

The liquidator can be paid in the **underlying** asset (DAI) or in the **aToken** (aDAI), using `receiveAToken`.

## `LendingPool.liquidationCall` ([04:33:20](https://www.youtube.com/watch?v=aq2cMmibayI&t=16400s) started · [06:54:49](https://www.youtube.com/watch?v=aq2cMmibayI&t=24889s) finished)

```solidity
function liquidationCall(
    address collateral,      // asset to seize
    address reserve,         // asset being repaid
    address user,            // borrower
    uint256 purchaseAmount,  // how much debt the liquidator wants to repay
    bool receiveAToken       // get aTokens instead of the underlying
) external payable nonReentrant onlyActiveReserve(reserve) onlyActiveReserve(collateral) {
    address liquidationManager = s_addressesProvider.getLendingPoolLiquidationManager();

    // run the manager's code against the LendingPool's own storage
    (bool success, bytes memory result) = liquidationManager.delegatecall(
        abi.encodeCall(
            ILiquidationManager.liquidationCall,
            (collateral, reserve, user, purchaseAmount, receiveAToken)
        )
    );
    if (!success) revert LendingPool__LiquidationCallFailed();

    // the manager returns (code, message) instead of reverting
    (uint256 returnCode, string memory returnMessage) = abi.decode(result, (uint256, string));
    if (returnCode != 0) revert LendingPool__LiquidationFailed(returnMessage);
}
```

The addresses provider gets a `LENDING_POOL_LIQUIDATION_MANAGER` key with a setter, event and getter.

```solidity
interface ILiquidationManager {
    function liquidationCall(address collateral, address reserve, address user, uint256 purchaseAmount, bool receiveAToken)
        external payable returns (uint256, string memory);
}
```

## Why `delegatecall`? ([04:39:33](https://www.youtube.com/watch?v=aq2cMmibayI&t=16773s))

- A normal call (`manager.liquidationCall(...)`) runs in the **manager's** context, with its own storage and `msg.sender = LendingPool`.
- A `delegatecall` **borrows the manager's code and runs it in the LendingPool's context**: the pool's storage, the pool's balance, and the original `msg.sender` (the liquidator).

What follows from that:
1. **Same storage layout.** The manager declares the same state variables, in the same order: `s_addressesProvider`, `s_core`, `s_dataProvider`, `s_parametersProvider`, `s_feeProvider`. This is why Part 1 made these ordinary storage variables and not `immutable`. Immutables live in bytecode, so the manager wouldn't see the pool's values.
2. **No constructor in the manager.** Its storage is never used. The pool's storage already holds the values.
3. When the manager's code calls `core.*` or `aToken.*`, the caller is the **LendingPool**, so their `onlyLendingPool` checks pass.
4. Expected failures (healthy position, wrong collateral…) come back as an **error code + message**. The pool decodes them and reverts with the message.

The manager's code is in [04](04-liquidation-manager.md).
