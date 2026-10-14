# 1. Borrow

▶ [Watch from 00:00:00](https://www.youtube.com/watch?v=aq2cMmibayI&t=0s) · Next: [02 Repay](02-repay.md)

## Recap: how much can I borrow? ([00:00:02](https://www.youtube.com/watch?v=aq2cMmibayI&t=2s))

- Collateral: 10 ETH. LTV 75%. 1 DAI = 0.0005 ETH (1 ETH = 2,000 DAI).
- Maximum debt in ETH = 10 × 0.75 = **7.5 ETH**.
- In DAI = 7.5 / 0.0005 = **15,000 DAI**. (The transcript says "50,000". The math gives 15,000.)
- Someone else must have deposited that DAI. You can only borrow what other users supplied. Borrowing less than the maximum is safer.

## Stable rate vs variable rate ([00:02:48](https://www.youtube.com/watch?v=aq2cMmibayI&t=168s))

In Aave V1 (and V2), a borrower chooses how interest is charged. Later versions removed the stable rate.

| | Variable | Stable |
|---|---|---|
| Does the rate change? | Yes, whenever pool conditions change (set by the interest rate strategy) | Usually not. It's the user's own rate, fixed when they borrow, like a fixed-rate mortgage |
| Where it's stored | the reserve's `currentVariableBorrowRate` + variable borrow index | the user's `UserReserveData.stableBorrowRate` |
| How debt grows | principal × (reserve index now / user's index) | principal × compound(user's stable rate, time since the user's last update) |

- A user has **one mode per borrowed asset** at a time.
- `getCompoundedBorrowBalance` ([Part 1 · 10](../part1/10-lending-pool-data-provider.md)) already handles both. `stableBorrowRate > 0` means the loan is stable, otherwise it's variable.
- When a variable rate changes, every variable borrower's debt follows automatically, because they all share one index.

The CoreLibrary enum:

```solidity
enum InterestRateMode { NONE, STABLE, VARIABLE }
```

## `LendingPool.borrow`: the checks ([00:13:43](https://www.youtube.com/watch?v=aq2cMmibayI&t=823s))

```solidity
function borrow(address reserve, uint256 amount, uint256 interestRateMode, uint16 referralCode)
    external nonReentrant
    onlyActiveReserve(reserve) onlyUnfreezedReserve(reserve) onlyAmountGreaterThanZero(amount)
{
    BorrowLocalVars memory vars; // avoids "stack too deep"

    // 1. Reserve must allow borrowing
    if (!s_core.isReserveBorrowingEnabled(reserve)) revert LendingPool__ReserveNotEnabledForBorrowing();

    // 2. Rate mode must be STABLE or VARIABLE
    if (interestRateMode != uint256(CoreLibrary.InterestRateMode.VARIABLE)
        && interestRateMode != uint256(CoreLibrary.InterestRateMode.STABLE)) {
        revert LendingPool__InvalidInterestRateMode();
    }
    vars.rateMode = CoreLibrary.InterestRateMode(interestRateMode);

    // 3. The reserve must actually hold that much
    vars.availableLiquidity = s_core.getReserveAvailableLiquidity(reserve);
    if (vars.availableLiquidity < amount) revert LendingPool__NotEnoughLiquidityInReserve();

    // 4. Read the borrower's global position
    (, vars.userCollateralBalanceETH, vars.userBorrowBalanceETH, vars.userTotalFeesETH,
     vars.currentLtv, vars.currentLiquidationThreshold, , vars.healthFactorBelowThreshold)
        = s_dataProvider.calculateUserGlobalData(msg.sender);

    if (vars.userCollateralBalanceETH == 0) revert LendingPool__CollateralBalanceIsZero();
    if (vars.healthFactorBelowThreshold) revert LendingPool__HealthFactorBelowThreshold();

    // 5. Origination fee; a fee of 0 means the amount is too small
    vars.borrowFee = s_feeProvider.calculateLoanOriginationFee(msg.sender, amount);
    if (vars.borrowFee == 0) revert LendingPool__AmountTooSmallToBorrow();

    // 6. Is there enough collateral for old debt + fees + this new loan?
    vars.amountOfCollateralNeededETH = s_dataProvider.calculateCollateralNeededInETH(
        reserve, amount, vars.borrowFee, vars.userBorrowBalanceETH, vars.userTotalFeesETH, vars.currentLtv);
    if (vars.amountOfCollateralNeededETH > vars.userCollateralBalanceETH) revert LendingPool__InsufficientCollateral();

    // 7. Extra rules for stable-rate loans (below)
    // 8. Update state, 9. send the asset, 10. emit Borrow
```

Small core getters added along the way: `isReserveBorrowingEnabled`, `getReserveDecimals`, `getUserOriginationFee`, `isReserveUsageAsCollateralEnabled`.

### LendingPool storage order matters

The new state variables are `s_dataProvider`, `s_parametersProvider` and `s_feeProvider`. They're ordinary storage variables, not immutables, set in the constructor from the addresses provider. The LiquidationManager will copy this exact layout ([03](03-liquidation.md)), because it runs through `delegatecall`.

## Fee provider ([00:32:37](https://www.youtube.com/watch?v=aq2cMmibayI&t=1957s))

```solidity
interface IFeeProvider {
    function calculateLoanOriginationFee(address user, uint256 amount) external view returns (uint256);
    function getLoanOriginationFeePercentage() external view returns (uint256);
}
```

The addresses provider gets a `FEE_PROVIDER` key with a setter, event and getter. The **origination fee** is charged once, when you borrow, and is stored on the user's reserve record. It counts as debt in the health factor. The tests use 0.25%, Aave V1's default. For example, 0.02 WETH × 0.25% = 0.00005 WETH.

## `calculateCollateralNeededInETH` (data provider) ([00:40:34](https://www.youtube.com/watch?v=aq2cMmibayI&t=2434s))

Since LTV = debt / collateral, **collateral needed = total debt / LTV**.

```solidity
function calculateCollateralNeededInETH(
    address reserve,
    uint256 amount,
    uint256 fee,
    uint256 userCurrentBorrowBalanceETH,
    uint256 userCurrentFeesETH,
    uint256 userCurrentLtv
) external view returns (uint256) {
    uint256 reserveDecimals = i_core.getReserveDecimals(reserve);
    IPriceOracleGetter oracle = IPriceOracleGetter(i_addressesProvider.getPriceOracle());

    // new debt (amount + fee) priced in ETH
    uint256 requestedBorrowAmountETH = (oracle.getAssetPrice(reserve) * (amount + fee)) / (10 ** reserveDecimals);

    // (existing debt + existing fees + new debt) / LTV
    uint256 collateralNeededInETH =
        ((userCurrentBorrowBalanceETH + userCurrentFeesETH + requestedBorrowAmountETH) * 100) / userCurrentLtv;
    return collateralNeededInETH;
}
```

Worked example from the video and its unit test:
- Borrow 1,000 DAI, fee 10 DAI, DAI = 0.0005 ETH → new debt = 1,010 × 0.0005 = **0.505 ETH**.
- Existing borrow 0.5 ETH, existing fees 0.05 ETH, LTV 75.
- Collateral needed = (0.5 + 0.05 + 0.505) × 100 / 75 ≈ **1.4067 ETH**.
- A second test does the same with a 6-decimals token, to check that the decimals scaling works.

## Stable-rate rules ([01:00:16](https://www.youtube.com/watch?v=aq2cMmibayI&t=3616s) · [01:08:17](https://www.youtube.com/watch?v=aq2cMmibayI&t=4097s))

A stable loan locks in a rate, so Aave limits it:
1. The reserve must have stable borrowing enabled.
2. You **can't borrow at a stable rate in the same currency that is mostly your collateral**. Otherwise someone could deposit a lot, borrow it back at a cheap fixed rate, and game the system.
3. One stable loan can take at most **25% of the reserve's available liquidity**.

**LendingPoolParametersProvider** (`src/configuration/`) holds this setting:

```solidity
contract LendingPoolParametersProvider {
    uint256 private constant MAX_STABLE_RATE_BORROW_SIZE_PERCENT = 25;
    function getMaxStableRateBorrowSizePercent() external pure returns (uint256) {
        return MAX_STABLE_RATE_BORROW_SIZE_PERCENT;
    }
}
```
It's registered in the addresses provider and loaded into `s_parametersProvider`.

Core check:

```solidity
function isUserAllowedToBorrowAtStable(address reserve, address user, uint256 amount) external view returns (bool) {
    CoreLibrary.ReserveData storage r = s_reserves[reserve];
    CoreLibrary.UserReserveData storage u = s_usersReserveData[user][reserve];

    if (!r.isStableBorrowRateEnabled) return false;

    // allowed if ANY is true:
    return !u.useAsCollateral                              // user isn't using this asset as collateral
        || !r.usageAsCollateralEnabled                     // the reserve can't be collateral at all
        || amount > getUserUnderlyingAssetBalance(reserve, user); // borrowing more than they deposited of it
}
```

In `borrow`:

```solidity
    if (vars.rateMode == CoreLibrary.InterestRateMode.STABLE) {
        if (!s_core.isUserAllowedToBorrowAtStable(reserve, msg.sender, amount)) {
            revert LendingPool__UserCannotBorrowAtStableRate();
        }
        uint256 maxLoanPercent = s_parametersProvider.getMaxStableRateBorrowSizePercent();
        uint256 maxLoanSizeStable = (vars.availableLiquidity * maxLoanPercent) / 100; // 1,000 available → 250 max
        if (amount > maxLoanSizeStable) revert LendingPool__BorrowingTooMuchAtStableRate();
    }
```

---

## Core: `updateStateOnBorrow` ([01:21:08](https://www.youtube.com/watch?v=aq2cMmibayI&t=4868s))

```solidity
function updateStateOnBorrow(
    address reserve, address user, uint256 amountBorrowed, uint256 borrowFee, CoreLibrary.InterestRateMode rateMode
) external onlyLendingPool returns (uint256, uint256) {
    // 1. the user's debt so far: principal and interest earned since their last update
    (uint256 principalBorrowBalance, , uint256 balanceIncrease) = getUserBorrowBalances(reserve, user);

    // 2. reserve: indexes + stable/variable totals
    _updateReserveStateOnBorrow(reserve, user, principalBorrowBalance, balanceIncrease, amountBorrowed, rateMode);

    // 3. user: rate, index, principal, fee, timestamp
    _updateUserStateOnBorrow(reserve, user, amountBorrowed, balanceIncrease, borrowFee, rateMode);

    // 4. liquidity left the reserve → new rates
    _updateReserveInterestRatesAndTimestamp(reserve, 0, amountBorrowed);

    // returns the rate the user now pays, and the interest added to their principal
    return (getUserCurrentBorrowRate(reserve, user), balanceIncrease);
}
```

### `getUserBorrowBalances` ([01:25:37](https://www.youtube.com/watch?v=aq2cMmibayI&t=5137s))

```solidity
/// @return principal, compounded balance (principal + interest), balance increase since last update
function getUserBorrowBalances(address reserve, address user) public view returns (uint256, uint256, uint256) {
    CoreLibrary.UserReserveData storage u = s_usersReserveData[user][reserve];
    uint256 principal = u.principalBorrowBalance;
    if (principal == 0) return (0, 0, 0);

    uint256 compoundedBalance = CoreLibrary.getCompoundedBorrowBalance(u, s_reserves[reserve]);
    return (principal, compoundedBalance, compoundedBalance - principal);
}
```

### Reserve side ([01:32:11](https://www.youtube.com/watch?v=aq2cMmibayI&t=5531s))

```solidity
function _updateReserveStateOnBorrow(address reserve, address user, uint256 principalBorrowBalance,
    uint256 balanceIncrease, uint256 amountBorrowed, CoreLibrary.InterestRateMode rateMode) internal
{
    s_reserves[reserve].updateCumulativeIndexes(); // settle deposit + variable interest up to now
    _updateReserveTotalBorrowsByRateMode(reserve, user, principalBorrowBalance, balanceIncrease, amountBorrowed, rateMode);
}
```

#### `_updateReserveTotalBorrowsByRateMode` ([01:35:44](https://www.youtube.com/watch?v=aq2cMmibayI&t=5744s))

The approach: **take the user's old principal out of whichever total it was in, then put the whole new principal into the total for the new mode.** This one function covers first borrows, borrowing more in the same mode, and switching modes.

```solidity
function _updateReserveTotalBorrowsByRateMode(address reserve, address user, uint256 principalBalance,
    uint256 balanceIncrease, uint256 amountBorrowed, CoreLibrary.InterestRateMode newBorrowRateMode) internal
{
    CoreLibrary.InterestRateMode previousRateMode = getUserCurrentBorrowRateMode(reserve, user);
    CoreLibrary.ReserveData storage r = s_reserves[reserve];

    // 1. remove the previous principal from its old bucket
    if (previousRateMode == CoreLibrary.InterestRateMode.STABLE) {
        CoreLibrary.UserReserveData storage u = s_usersReserveData[user][reserve];
        r.decreaseTotalBorrowsStableAndUpdateAverageRate(principalBalance, u.stableBorrowRate);
    } else if (previousRateMode == CoreLibrary.InterestRateMode.VARIABLE) {
        r.decreaseTotalBorrowsVariable(principalBalance);
    } // NONE → first borrow, nothing to remove

    // 2. new principal = old principal + interest earned + new loan
    uint256 newPrincipalAmount = principalBalance + balanceIncrease + amountBorrowed;

    // 3. add it to the new bucket
    if (newBorrowRateMode == CoreLibrary.InterestRateMode.STABLE) {
        r.increaseTotalBorrowsStableAndUpdateAverageRate(newPrincipalAmount, r.currentStableBorrowRate);
    } else if (newBorrowRateMode == CoreLibrary.InterestRateMode.VARIABLE) {
        r.increaseTotalBorrowsVariable(newPrincipalAmount);
    } else {
        revert LendingPoolCore__InvalidBorrowRateMode();
    }
}

function getUserCurrentBorrowRateMode(address reserve, address user) public view returns (CoreLibrary.InterestRateMode) {
    CoreLibrary.UserReserveData storage u = s_usersReserveData[user][reserve];
    if (u.principalBorrowBalance == 0) return CoreLibrary.InterestRateMode.NONE;
    return u.stableBorrowRate > 0 ? CoreLibrary.InterestRateMode.STABLE : CoreLibrary.InterestRateMode.VARIABLE;
}
```

#### The stable average rate (CoreLibrary)

The reserve tracks one **weighted average stable rate**: Σ(debtᵢ × rateᵢ) / Σ debtᵢ. Adding or removing a stable loan updates it.

**Remove** ([01:46:09](https://www.youtube.com/watch?v=aq2cMmibayI&t=6369s)): newAvg = (prevTotal × prevAvg − removed × removedRate) / remaining

```solidity
function decreaseTotalBorrowsStableAndUpdateAverageRate(ReserveData storage reserve, uint256 amount, uint256 rate) internal {
    if (reserve.totalBorrowsStable < amount) revert CoreLibrary__InvalidAmount();

    uint256 previousTotalBorrowStable = reserve.totalBorrowsStable;
    reserve.totalBorrowsStable -= amount;

    if (reserve.totalBorrowsStable == 0) {          // no stable debt left → no average
        reserve.currentAverageStableBorrowRate = 0;
        return;
    }

    uint256 weightedLastBorrow = amount.wadToRay().rayMul(rate);
    uint256 weightedPreviousTotalBorrows =
        previousTotalBorrowStable.wadToRay().rayMul(reserve.currentAverageStableBorrowRate);
    if (weightedPreviousTotalBorrows < weightedLastBorrow) revert CoreLibrary__AmountSubtractionUnderflow();

    reserve.currentAverageStableBorrowRate =
        (weightedPreviousTotalBorrows - weightedLastBorrow).rayDiv(reserve.totalBorrowsStable.wadToRay());
}
```
Test: 1,500 at an average of 6%, remove 500 at 8% → (90 − 40) / 1,000 = **5%**, remaining 1,000.

**Add** ([02:12:08](https://www.youtube.com/watch?v=aq2cMmibayI&t=7928s)): newAvg = (prevTotal × prevAvg + new × newRate) / newTotal

```solidity
function increaseTotalBorrowsStableAndUpdateAverageRate(ReserveData storage reserve, uint256 amount, uint256 rate) internal {
    uint256 previousTotalBorrowStable = reserve.totalBorrowsStable;
    reserve.totalBorrowsStable += amount;

    uint256 weightedLastBorrow = amount.wadToRay().rayMul(rate);
    uint256 weightedPreviousTotalBorrows =
        previousTotalBorrowStable.wadToRay().rayMul(reserve.currentAverageStableBorrowRate);

    reserve.currentAverageStableBorrowRate =
        (weightedLastBorrow + weightedPreviousTotalBorrows).rayDiv(reserve.totalBorrowsStable.wadToRay());
}
```
Test: 1,000 at 5% + 500 at 8% → (50 + 40) / 1,500 = **6%**, total 1,500.

**Variable** totals have no average, so they're a plain add or subtract ([02:03:53](https://www.youtube.com/watch?v=aq2cMmibayI&t=7433s), [02:20:33](https://www.youtube.com/watch?v=aq2cMmibayI&t=8433s)):

```solidity
function decreaseTotalBorrowsVariable(ReserveData storage reserve, uint256 amount) internal {
    if (reserve.totalBorrowsVariable < amount) revert CoreLibrary__InvalidAmount();
    reserve.totalBorrowsVariable -= amount;
}
function increaseTotalBorrowsVariable(ReserveData storage reserve, uint256 amount) internal {
    reserve.totalBorrowsVariable += amount;
}
```

The instructor first put the decrease helper in LendingPoolCore, then moved it to CoreLibrary where it belongs.

The rate-mode tests cover every transition: NONE→VARIABLE, NONE→STABLE, STABLE→STABLE, VARIABLE→VARIABLE, STABLE→VARIABLE, VARIABLE→STABLE. Two examples:
- **NONE → VARIABLE, 500**: variable total +500, stable total and average unchanged.
- **NONE → STABLE, 500 at 5%** (average already 5%): stable 1,000 → 1,500, average stays **5%**.
- To make a user count as "stable" in a test, set their `stableBorrowRate` > 0, because that's what `getUserCurrentBorrowRateMode` reads.

### User side ([02:31:53](https://www.youtube.com/watch?v=aq2cMmibayI&t=9113s))

```solidity
function _updateUserStateOnBorrow(address reserve, address user, uint256 amountBorrowed,
    uint256 balanceIncrease, uint256 fee, CoreLibrary.InterestRateMode rateMode) internal
{
    CoreLibrary.ReserveData storage r = s_reserves[reserve];
    CoreLibrary.UserReserveData storage u = s_usersReserveData[user][reserve];

    if (rateMode == CoreLibrary.InterestRateMode.STABLE) {
        u.stableBorrowRate = r.currentStableBorrowRate;          // lock in the user's own rate
        u.lastVariableBorrowCumulativeIndex = 0;
    } else if (rateMode == CoreLibrary.InterestRateMode.VARIABLE) {
        u.stableBorrowRate = 0;
        u.lastVariableBorrowCumulativeIndex = r.lastVariableBorrowCumulativeIndex; // checkpoint
    } else {
        revert LendingPoolCore__InvalidBorrowRateMode();
    }

    u.principalBorrowBalance += amountBorrowed + balanceIncrease; // interest earned becomes principal
    u.originationFee += fee;   // Aave V1 adds to the fee; the transcript sounds like plain "="
    u.lastUpdateTimestamp = uint40(block.timestamp);
}
```

### `getUserCurrentBorrowRate` ([02:42:02](https://www.youtube.com/watch?v=aq2cMmibayI&t=9722s))

```solidity
function getUserCurrentBorrowRate(address reserve, address user) internal view returns (uint256) {
    CoreLibrary.InterestRateMode rateMode = getUserCurrentBorrowRateMode(reserve, user);
    if (rateMode == CoreLibrary.InterestRateMode.NONE) return 0;
    return rateMode == CoreLibrary.InterestRateMode.STABLE
        ? s_usersReserveData[user][reserve].stableBorrowRate   // personal rate
        : s_reserves[reserve].currentVariableBorrowRate;        // shared rate
}
```

**`updateStateOnBorrow` test (NONE → VARIABLE)**: the core holds 1,000, the user borrows 100 at variable. The mock strategy rates are 3% / 6% / 7%. After 1 month with no previous borrows, interest earned = 0, so the indexes don't move. The function returns the 7% variable rate, total variable = 100, total stable = 0, average = 0, new rates are stored, and the user record has principal 100, fee, index checkpoint and timestamp.

## Finishing `borrow` ([02:54:16](https://www.youtube.com/watch?v=aq2cMmibayI&t=10456s))

```solidity
    (vars.finalUserBorrowRate, vars.borrowBalanceIncrease) =
        s_core.updateStateOnBorrow(reserve, msg.sender, amount, vars.borrowFee, vars.rateMode);

    s_core.transferToUser(reserve, payable(msg.sender), amount); // core sends the asset

    emit Borrow(reserve, msg.sender, amount, interestRateMode, vars.finalUserBorrowRate,
        vars.borrowFee, vars.borrowBalanceIncrease, referralCode, block.timestamp);
}
```

## Integration tests ([02:56:43](https://www.youtube.com/watch?v=aq2cMmibayI&t=10603s))

**Happy path (variable).**
- Alice deposits 100 DAI. At 0.0005 ETH per DAI that's **0.05 ETH** of collateral. LTV 75% → she can borrow up to **0.0375 ETH**.
- Bob deposits 1 WETH, so there is WETH to lend.
- Alice borrows **0.02 WETH variable**. That's well within the limit, even with the fee.
- Checks: Alice's WETH = 0.02 · principal = compounded = 0.02 (no time passed) · mode = VARIABLE · her DAI is still collateral · origination fee recorded · core WETH = 1 − 0.02, from both `getReserveAvailableLiquidity` and `WETH.balanceOf(core)`.

Other tests:
- The same for a **stable** loan, which sets different user fields.
- **Redeem the maximum safe collateral** while in debt: OK. Redeem slightly more: reverts `AToken__TransferNotAllowed` (HF would drop below 1).
- **Redeem everything** while in debt: reverts.
- A **second variable borrow** first adds the interest earned on the first one to the principal, and moves the reserve index forward.
- **Price shock**: DAI price halves (0.0005 → 0.00025 ETH), the position becomes unsafe, and no collateral can be withdrawn.

## Recap

Borrow = checks (enabled, mode, liquidity, collateral > 0, HF ≥ 1, fee > 0, enough collateral, stable rules) → core: settle indexes → move the user's principal between stable and variable totals (and update the weighted stable average) → update the user record → reprice → send the asset.
