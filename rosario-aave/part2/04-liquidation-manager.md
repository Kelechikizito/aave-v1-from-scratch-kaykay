# 4. LendingPoolLiquidationManager

▶ [Watch from 04:44:53](https://www.youtube.com/watch?v=aq2cMmibayI&t=17093s) · Previous: [03 Liquidation](03-liquidation.md) · Next: [05 Swap / rebalance / flash loan](05-swap-rebalance-flashloan.md)

This is the code the LendingPool runs through `delegatecall` (see [03](03-liquidation.md)). The chapter also adds new functions to **LendingPoolCore** and the **AToken**.

## Skeleton ([04:46:31](https://www.youtube.com/watch?v=aq2cMmibayI&t=17191s) · [04:52:36](https://www.youtube.com/watch?v=aq2cMmibayI&t=17556s))

```solidity
contract LendingPoolLiquidationManager is ReentrancyGuard {
    using WadRayMath for uint256;

    enum LiquidationErrors {
        NO_ERROR,                         // 0 = success
        NO_COLLATERAL_AVAILABLE,
        COLLATERAL_CANNOT_BE_LIQUIDATED,
        CURRENCY_NOT_BORROWED,
        HEALTH_FACTOR_ABOVE_THRESHOLD,
        NOT_ENOUGH_LIQUIDITY
    }

    // SAME storage layout as LendingPool (delegatecall)
    LendingPoolAddressesProvider private s_addressesProvider;
    LendingPoolCore private s_core;
    LendingPoolDataProvider private s_dataProvider;
    LendingPoolParametersProvider private s_parametersProvider;
    IFeeProvider private s_feeProvider;

    uint256 private constant LIQUIDATION_CLOSE_FACTOR_PERCENT = 50;
    // no constructor: only ever runs via delegatecall
```

## `liquidationCall` step by step

```solidity
function liquidationCall(address collateral, address reserve, address user, uint256 purchaseAmount, bool receiveAToken)
    external payable returns (uint256, string memory)
{
    LiquidationCallLocalVars memory vars;

    // 1. Only unhealthy positions (HF < 1) can be liquidated
    (, , , , , , , vars.healthFactorBelowThreshold) = s_dataProvider.calculateUserGlobalData(user);
    if (!vars.healthFactorBelowThreshold) {
        return (uint256(LiquidationErrors.HEALTH_FACTOR_ABOVE_THRESHOLD), "Health factor is not below the threshold");
    }

    // 2. The borrower must hold some of the chosen collateral
    vars.userCollateralBalance = s_core.getUserUnderlyingAssetBalance(collateral, user);
    if (vars.userCollateralBalance == 0) {
        return (uint256(LiquidationErrors.NO_COLLATERAL_AVAILABLE), "Invalid collateral to liquidate");
    }

    // 3. It must be collateral on BOTH sides: the reserve allows it AND the user enabled it
    vars.isCollateralEnabled = s_core.isReserveUsageAsCollateralEnabled(collateral)
        && s_core.isUserUseReserveAsCollateralEnabled(collateral, user);
    if (!vars.isCollateralEnabled) {
        return (uint256(LiquidationErrors.COLLATERAL_CANNOT_BE_LIQUIDATED), "The collateral chosen cannot be liquidated");
    }

    // 4. The borrower must owe the chosen debt asset
    (, vars.userCompoundedBorrowBalance, vars.borrowBalanceIncrease) = s_core.getUserBorrowBalances(reserve, user);
    if (vars.userCompoundedBorrowBalance == 0) {
        return (uint256(LiquidationErrors.CURRENCY_NOT_BORROWED), "User did not borrow the specified currency");
    }

    // 5. Close factor: repay at most 50% of the debt
    vars.maxPrincipalAmountToLiquidate = (vars.userCompoundedBorrowBalance * LIQUIDATION_CLOSE_FACTOR_PERCENT) / 100;
    vars.actualAmountToLiquidate = purchaseAmount > vars.maxPrincipalAmountToLiquidate
        ? vars.maxPrincipalAmountToLiquidate
        : purchaseAmount;

    // 6. How much collateral that buys (with bonus), capped by what the borrower has
    (uint256 maxCollateralToLiquidate, uint256 principalAmountNeeded) = calculateAvailableCollateralToLiquidate(
        collateral, reserve, vars.actualAmountToLiquidate, vars.userCollateralBalance);

    // 7. Outstanding origination fee → paid from the collateral that's LEFT
    vars.originationFee = s_core.getUserOriginationFee(reserve, user);
    if (vars.originationFee > 0) {
        (vars.liquidatedCollateralForFee, vars.feeLiquidated) = calculateAvailableCollateralToLiquidate(
            collateral, reserve, vars.originationFee, vars.userCollateralBalance - maxCollateralToLiquidate);
    }

    // 8. Not enough collateral → shrink the repayment to what it covers
    if (principalAmountNeeded < vars.actualAmountToLiquidate) vars.actualAmountToLiquidate = principalAmountNeeded;

    // 9. Paying out underlying? The collateral reserve must have the cash
    if (!receiveAToken) {
        uint256 currentAvailableCollateral = s_core.getReserveAvailableLiquidity(collateral);
        if (currentAvailableCollateral < maxCollateralToLiquidate) {
            return (uint256(LiquidationErrors.NOT_ENOUGH_LIQUIDITY), "There isn't enough liquidity available to liquidate");
        }
    }

    // 10. Accounting BEFORE moving any assets
    s_core.updateStateOnLiquidation(reserve, collateral, user, vars.actualAmountToLiquidate, maxCollateralToLiquidate,
        vars.feeLiquidated, vars.liquidatedCollateralForFee, vars.borrowBalanceIncrease, receiveAToken);

    AToken collateralAToken = AToken(s_core.getReserveATokenAddress(collateral));

    // 11. Pay the liquidator
    if (receiveAToken) {
        collateralAToken.transferOnLiquidation(user, msg.sender, maxCollateralToLiquidate); // move aDAI
    } else {
        collateralAToken.burnOnLiquidation(user, maxCollateralToLiquidate);                // burn aDAI
        s_core.transferToUser(collateral, payable(msg.sender), maxCollateralToLiquidate);  // send DAI
    }

    // 12. Collect the debt repayment from the liquidator
    s_core.transferToReserve{value: msg.value}(reserve, payable(msg.sender), vars.actualAmountToLiquidate);

    // 13. Seize collateral for the fee and send it to the fee collector
    if (vars.feeLiquidated > 0) {
        collateralAToken.burnOnLiquidation(user, vars.liquidatedCollateralForFee);
        s_core.liquidateFee(collateral, vars.liquidatedCollateralForFee, s_addressesProvider.getTokenDistributor());
        emit OriginationFeeLiquidated(collateral, reserve, user, vars.feeLiquidated,
            vars.liquidatedCollateralForFee, block.timestamp);
    }

    emit LiquidationCall(collateral, reserve, user, vars.actualAmountToLiquidate, maxCollateralToLiquidate,
        vars.borrowBalanceIncrease, msg.sender, receiveAToken, block.timestamp);

    return (uint256(LiquidationErrors.NO_ERROR), "No errors");
}
```

New core getter: `isReserveUsageAsCollateralEnabled(reserve)`.

## `calculateAvailableCollateralToLiquidate` ([05:12:37](https://www.youtube.com/watch?v=aq2cMmibayI&t=18757s))

> **maxCollateral = (debtPrice × repayAmount / collateralPrice) × bonus / 100**

If that's more than the borrower has, take all of it and work backwards to the repayment it covers:

> **principalNeeded = (collateralPrice × collateralAmount / debtPrice) × 100 / bonus**

```solidity
function calculateAvailableCollateralToLiquidate(
    address collateral,          // asset to seize
    address principal,           // debt asset being repaid
    uint256 purchaseAmount,      // debt to repay
    uint256 userCollateralBalance
) internal view returns (uint256 collateralAmount, uint256 principalAmountNeeded) {
    collateralAmount = 0;
    principalAmountNeeded = 0;
    IPriceOracleGetter oracle = IPriceOracleGetter(s_addressesProvider.getPriceOracle());

    AvailableCollateralToLiquidateLocalVars memory vars;
    vars.collateralPrice = oracle.getAssetPrice(collateral);
    vars.principalCurrencyPrice = oracle.getAssetPrice(principal);
    vars.liquidationBonus = s_core.getReserveLiquidationBonus(collateral);

    vars.maxAmountCollateralToLiquidate =
        (((vars.principalCurrencyPrice * purchaseAmount) / vars.collateralPrice) * vars.liquidationBonus) / 100;

    if (vars.maxAmountCollateralToLiquidate > userCollateralBalance) {
        collateralAmount = userCollateralBalance;
        principalAmountNeeded =
            (((vars.collateralPrice * collateralAmount) / vars.principalCurrencyPrice) * 100) / vars.liquidationBonus;
    } else {
        collateralAmount = vars.maxAmountCollateralToLiquidate;
        principalAmountNeeded = purchaseAmount;
    }
    return (collateralAmount, principalAmountNeeded);
}
```

Like Aave V1, this formula ignores token decimals, so it's only correct when both assets have the same decimals.

New core getter: `getReserveLiquidationBonus(reserve)`.

**Tests** ([05:31:47](https://www.youtube.com/watch?v=aq2cMmibayI&t=19907s)), repaying 100 DAI at 0.0005 ETH, collateral WETH at 1 ETH, bonus 105:
- Enough collateral: 100 × 0.0005 / 1 = 0.05 → × 1.05 = **0.0525 WETH**, and principal needed = 100.
- Borrower has only **0.05 WETH** → collateral capped at 0.05, principal needed = 0.05 / 0.0005 × 100/105 ≈ **95.24 DAI**.

## Core: `updateStateOnLiquidation` ([05:42:28](https://www.youtube.com/watch?v=aq2cMmibayI&t=20548s))

```solidity
function updateStateOnLiquidation(
    address principalReserve, address collateralReserve, address user,
    uint256 amountToLiquidate, uint256 collateralToLiquidate,
    uint256 feeLiquidated, uint256 liquidatedCollateralForFee,
    uint256 balanceIncrease, bool liquidatorReceivesAToken
) external onlyLendingPool {
    _updatePrincipalReserveStateOnLiquidation(principalReserve, user, amountToLiquidate, balanceIncrease); // 1
    _updateCollateralReserveStateOnLiquidation(collateralReserve);                                         // 2
    _updateUserStateOnLiquidation(principalReserve, user, amountToLiquidate, feeLiquidated, balanceIncrease); // 3
    _updateReserveInterestRatesAndTimestamp(principalReserve, amountToLiquidate, 0);                       // 4 debt repaid → liquidity in

    if (!liquidatorReceivesAToken) {                                                                       // 5 underlying leaves
        _updateReserveInterestRatesAndTimestamp(collateralReserve, 0, collateralToLiquidate + liquidatedCollateralForFee);
    }
}
```

**1. Debt reserve** ([05:47:15](https://www.youtube.com/watch?v=aq2cMmibayI&t=20835s)): the same pattern as repay: total + interest − repaid, in the user's bucket.

```solidity
function _updatePrincipalReserveStateOnLiquidation(address principalReserve, address user,
    uint256 amountToLiquidate, uint256 balanceIncrease) internal
{
    CoreLibrary.ReserveData storage r = s_reserves[principalReserve];
    CoreLibrary.UserReserveData storage u = s_usersReserveData[user][principalReserve];

    r.updateCumulativeIndexes();
    CoreLibrary.InterestRateMode borrowRateMode = getUserCurrentBorrowRateMode(principalReserve, user);

    if (borrowRateMode == CoreLibrary.InterestRateMode.STABLE) {
        r.increaseTotalBorrowsStableAndUpdateAverageRate(balanceIncrease, u.stableBorrowRate);
        r.decreaseTotalBorrowsStableAndUpdateAverageRate(amountToLiquidate, u.stableBorrowRate);
    } else {
        r.increaseTotalBorrowsVariable(balanceIncrease);
        r.decreaseTotalBorrowsVariable(amountToLiquidate);
    }
}
```
Test (variable, 1 year, 4% / 10%): variable 100 + 10 − 30 = **80**. Stable total and average unchanged. Indexes moved using the **old** rates.

**2. Collateral reserve** ([05:58:24](https://www.youtube.com/watch?v=aq2cMmibayI&t=21504s)): only `s_reserves[collateralReserve].updateCumulativeIndexes()`.

**3. Borrower** ([06:00:13](https://www.youtube.com/watch?v=aq2cMmibayI&t=21613s)):

```solidity
function _updateUserStateOnLiquidation(address reserve, address user, uint256 amountToLiquidate,
    uint256 feeLiquidated, uint256 balanceIncrease) internal
{
    CoreLibrary.UserReserveData storage u = s_usersReserveData[user][reserve];
    CoreLibrary.ReserveData storage r = s_reserves[reserve];

    u.principalBorrowBalance = u.principalBorrowBalance + balanceIncrease - amountToLiquidate;

    if (getUserCurrentBorrowRateMode(reserve, user) == CoreLibrary.InterestRateMode.VARIABLE) {
        u.lastVariableBorrowCumulativeIndex = r.lastVariableBorrowCumulativeIndex; // new checkpoint
    }
    if (feeLiquidated > 0) u.originationFee -= feeLiquidated;
    u.lastUpdateTimestamp = uint40(block.timestamp);
}
```
Test: principal 100, fee 5, index 1.0 → 1.2, liquidate 40, fee 2, interest 10 → principal **70**, fee **3**, index 1.2. Liquidating more than is owed → panic.

**Combined test**: reserve 50 stable / 100 variable. User 100 variable, fee 5. Liquidate 40, interest 10, fee 2 → variable total **70**, user principal 70, fee 3, new rates. With `receiveAToken = true`, the collateral reserve's rates aren't recalculated.

## AToken additions

### `_executeTransfer` ([06:18:51](https://www.youtube.com/watch?v=aq2cMmibayI&t=22731s))

A plain ERC20 transfer isn't enough. Both sides must first have their earned interest minted, or the transfer would use stale balances.

```solidity
function _executeTransfer(address from, address to, uint256 value) internal {
    if (value == 0) revert AToken__AmountMustBeGreaterThanZero();

    // 1. Mint each side's earned interest and move their checkpoints
    (, uint256 fromBalance, uint256 fromBalanceIncrease, uint256 fromIndex) = _cumulateBalance(from);
    (, , uint256 toBalanceIncrease, uint256 toIndex) = _cumulateBalance(to);

    // 2. Move the tokens with the normal ERC20 logic
    super._update(from, to, value);

    // 3. Sender emptied → reset their index
    bool fromIndexReset = false;
    if (fromBalance - value == 0) fromIndexReset = _resetDataOnZeroBalance(from);

    emit BalanceTransfer(from, to, value, fromBalanceIncrease, toBalanceIncrease,
        fromIndexReset ? 0 : fromIndex, toIndex);
}
```

### `_update` override ([06:26:04](https://www.youtube.com/watch?v=aq2cMmibayI&t=23164s))

In OpenZeppelin v5, `mint`, `burn`, `transfer` and `transferFrom` all go through `_update`. Overriding it routes every user transfer through the health check and the interest logic:

```solidity
function _update(address from, address to, uint256 value) internal override {
    // mint (from = 0) or burn (to = 0) → normal behaviour
    if (from == address(0) || to == address(0)) {
        super._update(from, to, value);
        return;
    }
    // a real transfer reduces `from`'s collateral → must keep HF ≥ 1
    if (!isTransferAllowed(from, value)) revert AToken__TransferNotAllowed();
    _executeTransfer(from, to, value);
}
```

Why the health check: aTokens are collateral. Sending them away lowers your collateral, which raises debt / collateral and can make you liquidatable.

The `_mint` inside `_cumulateBalance` goes through the mint branch, so there's no recursion.

**Tests** ([06:31:13](https://www.youtube.com/watch?v=aq2cMmibayI&t=23473s)): sender has 100 principal at index 1, recipient has 40, income is 1.05 → current balances **105 / 42**. Transfer 20 → sender **85**, recipient **62**, both indexes 1.05. Other tests: transferring the full balance resets the index · amount > balance reverts · `transfer` and `transferFrom` go through the same path.

### `transferOnLiquidation` ([06:37:28](https://www.youtube.com/watch?v=aq2cMmibayI&t=23848s))

```solidity
function transferOnLiquidation(address from, address to, uint256 value) external onlyLendingPool {
    _executeTransfer(from, to, value); // skips isTransferAllowed on purpose
}
```

This skips the health check: the borrower is already unhealthy, so the check would always fail.

### `burnOnLiquidation` ([06:39:33](https://www.youtube.com/watch?v=aq2cMmibayI&t=23973s))

```solidity
function burnOnLiquidation(address account, uint256 value) external onlyLendingPool {
    (, uint256 accountBalance, uint256 balanceIncrease, uint256 index) = _cumulateBalance(account); // mint interest first
    _burn(account, value);                                    // the deposit is gone; burn its receipt

    bool userIndexReset = false;
    if (accountBalance - value == 0) userIndexReset = _resetDataOnZeroBalance(account);

    emit BurnOnLiquidation(account, value, balanceIncrease, userIndexReset ? 0 : index);
}
```
Test: 100 at index 1, income 1.05 → 105. Burn 40 → **65**. Burning the full balance is also tested.

## Core: `liquidateFee` ([06:49:21](https://www.youtube.com/watch?v=aq2cMmibayI&t=24561s))

Sends the seized fee collateral from the core to the fee collector:

```solidity
function liquidateFee(address token, uint256 amount, address payable destination) external payable onlyLendingPool {
    if (token != EthAddressLib.ethAddress()) {
        IERC20(token).safeTransfer(destination, amount);
    } else {
        (bool success, ) = destination.call{value: amount}("");
        if (!success) revert LendingPoolCore__EthTransferFailed(destination, amount);
    }
}
```

## Integration test ([07:00:14](https://www.youtube.com/watch?v=aq2cMmibayI&t=25214s))

Setup:
1. User deposits 100 DAI (gets 100 aDAI). User 2 deposits 1 WETH.
2. User borrows **0.02 WETH variable**. Fee 0.25% → **0.00005 WETH**.
3. DAI = 0.0005 ETH → collateral 0.05 ETH. At an 80% LT it supports 0.04 ETH, so the position is safe.
4. **Price shock**: DAI → 0.00025 ETH. Collateral 0.025 ETH × 0.8 = 0.02 < 0.02 + 0.00005 of debt → **HF < 1**.

Liquidation (`receiveAToken = false`), the liquidator asks for 0.02 WETH:
- Capped to **0.01 WETH** (50%).
- Collateral = 0.01 / 0.00025 × 1.05 = **42 DAI** to the liquidator.
- Fee: 0.00005 / 0.00025 × 1.05 = **0.21 DAI** to the fee collector.
- Liquidator WETH −0.01. Liquidator DAI +42.
- Core DAI −42.21. Borrower's DAI collateral = 100 − 42 − 0.21 = **57.79**.
- WETH variable debt = 0.02 − 0.01.

Other tests: liquidator takes **aDAI** instead · the repayment is capped when the collateral is worth less · reverts when the position is healthy again · reverts for invalid collateral.

## Recap

The manager runs inside the pool. It checks HF < 1, the collateral and the debt; caps the repayment at 50%; prices the collateral plus bonus (capped by the borrower's balance); prices the fee from what collateral is left; updates the debt and collateral reserves and the user; pays the liquidator in aTokens (moved) or the underlying (burned, then sent); takes the repayment; and sends the fee to the collector.
