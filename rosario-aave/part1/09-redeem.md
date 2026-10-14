# 9. Redeem (the whole flow)

▶ Chapter starts at [06:19:54](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=22794s) · Previous: [08](08-atoken.md) · Next: [10 Data provider](10-lending-pool-data-provider.md)

The video starts redeem here, stops to build the data provider and explain health factor ([10](10-lending-pool-data-provider.md), [11](11-ltv-liquidation-threshold-health-factor.md)), and finishes it from **08:44:43** onward. This file puts all of it together. **Read 10 and 11 first** if you haven't.

## Redeem is the reverse of deposit

- Deposit: give DAI, get aDAI.
- Redeem: **burn aDAI**, the core sends the DAI back (plus interest).
- Unlike every other action, the user calls **`AToken.redeem`**, not the LendingPool.

```
user ──redeem(amount)──► AToken
                           ├─ cumulate interest, check health, burn aDAI
                           └─► LendingPool.redeemUnderlying
                                   ├─► Core.updateStateOnRedeem   (indexes, rates, collateral flag)
                                   └─► Core.transferToUser        (DAI/ETH out)
```

## `AToken.redeem` ([06:21:27](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=22887s) outline · [08:44:43](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=31483s) finished)

```solidity
function redeem(uint256 amount) external {
    if (amount == 0) revert AToken__AmountIsZero();

    // 1. Add earned interest to the principal (mint it) and move the checkpoint
    (, uint256 currentBalance, uint256 balanceIncrease, uint256 index) = _cumulateBalance(msg.sender);

    // 2. type(uint256).max means "redeem everything"
    uint256 amountToRedeem = amount;
    if (amount == UINT_MAX_VALUE) amountToRedeem = currentBalance;

    if (amountToRedeem > currentBalance) revert AToken__AmountToRedeemGreaterThanBalance();

    // 3. Make sure removing this collateral doesn't put a borrow position at risk
    if (!isTransferAllowed(msg.sender, amountToRedeem)) revert AToken__TransferNotAllowed();

    // 4. Burn the aTokens
    _burn(msg.sender, amountToRedeem);

    // 5. Nothing left → reset the user's index
    bool userIndexReset = false;
    if (currentBalance - amountToRedeem == 0) userIndexReset = _resetDataOnZeroBalance(msg.sender);

    // 6. Ask the pool to send the underlying asset
    i_pool.redeemUnderlying(
        i_underlyingAssetAddress, payable(msg.sender), amountToRedeem, currentBalance - amountToRedeem
    );

    emit Redeem(msg.sender, amountToRedeem, balanceIncrease, userIndexReset ? 0 : index);
}

function isTransferAllowed(address user, uint256 amount) public view returns (bool) {
    return i_dataProvider.balanceDecreaseAllowed(i_underlyingAssetAddress, user, amount);
}

function _resetDataOnZeroBalance(address user) internal returns (bool) {
    s_userIndexes[user] = 0; // user has no balance left
    return true;
}
```

The AToken also gets `i_dataProvider`, read from the addresses provider. The provider needs a `DATA_PROVIDER` key with a setter, event and getter.

`balanceDecreaseAllowed` is explained in [10](10-lending-pool-data-provider.md). With no borrows, it always returns `true`.

## `LendingPool.redeemUnderlying` ([≈08:55:11](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=32111s))

```solidity
modifier onlyOverlyingAToken(address reserve) {
    if (msg.sender != s_core.getReserveATokenAddress(reserve)) revert LendingPool__OnlyAToken();
    _;
}

function redeemUnderlying(address reserve, address payable user, uint256 amount, uint256 aTokenBalanceAfterRedeem)
    external nonReentrant
    onlyOverlyingAToken(reserve) onlyActiveReserve(reserve) onlyAmountGreaterThanZero(amount)
{
    uint256 currentAvailableLiquidity = s_core.getReserveAvailableLiquidity(reserve);
    if (currentAvailableLiquidity < amount) revert LendingPool__InsufficientLiquidity();

    s_core.updateStateOnRedeem(reserve, user, amount, aTokenBalanceAfterRedeem == 0);
    s_core.transferToUser(reserve, user, amount);

    emit RedeemUnderlying(reserve, user, amount, block.timestamp);
}
```

Only the reserve's own aToken can call this.

## Core: `updateStateOnRedeem` ([≈09:02:28](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=32548s))

```solidity
function updateStateOnRedeem(address reserve, address user, uint256 amountRedeemed, bool userRedeemedEverything)
    external onlyLendingPool
{
    // settle interest up to now (only moves if the reserve has borrows)
    s_reserves[reserve].updateCumulativeIndexes();
    // liquidity is leaving → new rates
    _updateReserveInterestRatesAndTimestamp(reserve, 0, amountRedeemed);
    // full exit → this reserve is no longer the user's collateral
    if (userRedeemedEverything) setUserUseReserveAsCollateral(reserve, user, false);
}
```

It's the same pattern as deposit, but the amount is passed as `liquidityTaken`.

Tests: indexes compound using the old rates, then the new rates and timestamp are saved · full redeem → `useAsCollateral = false` · partial → unchanged · non-pool caller → reverts.

## Core: `transferToUser` ([≈09:12:07](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=33127s))

```solidity
function transferToUser(address reserve, address payable user, uint256 amount) external onlyLendingPool {
    if (reserve != EthAddressLib.ethAddress()) {
        IERC20(reserve).safeTransfer(user, amount);
    } else {
        (bool result, ) = user.call{value: amount}("");
        if (!result) revert LendingPoolCore__TransferToUserFailed();
    }
}
```

It's the opposite of `transferToReserve`.

## Integration tests ([≈09:19:23](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=33563s))

**Partial redeem, no time passing.** Deposit 100 DAI, redeem 40:
- user DAI = 40 · core DAI = 60 · user aDAI = 60 · principal = 60 · index still 1 ray · still collateral.

**Full redeem, no time passing.** Deposit 100, redeem `type(uint256).max`:
- user DAI = 100 · core DAI = 0 · aDAI = 0 · principal = 0 · user index reset to 0 · `useAsCollateral = false`.

**Partial redeem after interest.** This uses `borrow()` from Part 2, because without borrows the indexes never move:
1. User deposits 100 DAI. A liquidity provider deposits 100 DAI.
2. A second user deposits 1 WETH as collateral and borrows 20 DAI at a variable rate.
3. `vm.warp` 1 year → normalized income = 1.05 → user's aDAI = 100 × 1.05 = **105**.
4. User redeems 40: mint 5 interest → burn 40 → index set to 1.05 → send 40 DAI.
5. User aDAI = 100 + 5 − 40 = **65** · user DAI = 40 · user index = 1.05.
6. Core DAI = 100 + 100 − 20 (borrowed) − 40 (redeemed) = **140**.

(Part 1 ends here, mid-test.)

## Recap

`AToken.redeem`: mint earned interest → work out the amount (max = all) → health check → burn → reset the index if the balance is now 0 → `pool.redeemUnderlying`: check liquidity → update indexes and rates (and drop the collateral flag on a full exit) → send the asset.
