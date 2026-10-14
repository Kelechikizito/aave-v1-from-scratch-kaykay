# 10. LendingPoolDataProvider

▶ Chapter starts at [06:28:40](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=23320s) · Previous: [09](09-redeem.md) · Next: [11 LTV / LT / HF](11-ltv-liquidation-threshold-health-factor.md)

> Read [11 (LTV, liquidation threshold, health factor)](11-ltv-liquidation-threshold-health-factor.md) **before** the health-factor sections below. Most of this file's code is written during the video's chapter 11 (≈06:55 to 08:41).

## What it is

A **read-only** contract that combines data. It holds no funds and changes no protocol state. It reads LendingPoolCore, the price oracle and the addresses provider, and combines them into risk numbers such as the user's total collateral in ETH, total debt in ETH, and health factor.

### Responsibilities
1. Calculate a user's **global position** across all reserves.
2. Calculate a user's **health factor**.
3. Check whether **lowering a user's aToken balance** keeps the position healthy (needed by redeem).
4. Calculate the collateral needed to cover a new borrow (Part 2).

## Constructor

```solidity
contract LendingPoolDataProvider {
    using WadRayMath for uint256;

    uint256 private constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18; // 1.0 in wad

    LendingPoolAddressesProvider private immutable i_addressesProvider;
    LendingPoolCore private immutable i_core;

    constructor(address addressesProvider) {
        if (addressesProvider == address(0)) revert LendingPoolDataProvider__ZeroAddress();
        i_addressesProvider = LendingPoolAddressesProvider(addressesProvider);
        address coreAddress = i_addressesProvider.getLendingPoolCore();
        if (coreAddress == address(0)) revert LendingPoolDataProvider__ZeroAddress();
        i_core = LendingPoolCore(coreAddress);
    }
```

Functions with many local variables put them in a `memory` struct (e.g. `BalanceDecreaseAllowedLocalVars`, `UserGlobalDataLocalVars`) to avoid the **"stack too deep"** compiler error.

## Core getter: reserve configuration

```solidity
function getReserveConfiguration(address reserve)
    external view returns (uint256 decimals, uint256 baseLTV, uint256 liquidationThreshold, bool usageAsCollateralEnabled)
{
    CoreLibrary.ReserveData storage r = s_reserves[reserve];
    return (r.decimals, r.baseLTVasCollateral, r.liquidationThreshold, r.usageAsCollateralEnabled);
}
```

## `calculateHealthFactorFromBalances` ([≈06:55:44](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=24944s))

**HF = (collateral × liquidationThreshold / 100) / (borrows + fees)**. Everything is in ETH, and the result is a wad.

```solidity
function _calculateHealthFactorFromBalances(
    uint256 collateralBalanceETH,
    uint256 borrowBalanceETH,
    uint256 totalFeesETH,
    uint256 liquidationThreshold
) internal pure returns (uint256) {
    if (borrowBalanceETH == 0) return type(uint256).max; // no debt → maximum health
    return ((collateralBalanceETH * liquidationThreshold) / 100).wadDiv(borrowBalanceETH + totalFeesETH);
}
```

The threshold is stored as a whole percentage (80, not 0.8). That's why the code divides by 100.

Tests: no borrow → `type(uint256).max` · collateral 2 ETH, borrow 1 ETH, fees 0.2 ETH, LT 80 → 1.6 / 1.2 = **1.333…e18**.

## Price oracle interface

```solidity
interface IPriceOracleGetter {
    /// @return price of one whole unit of `asset`, in ETH (wei)
    function getAssetPrice(address asset) external view returns (uint256);
}
```

Example: if 1 ETH = $2,000, then 1 DAI ($1) = 1/2000 = **0.0005 ETH**.

The addresses provider gets a `PRICE_ORACLE` key with a setter, event and `getPriceOracle()`.

## `calculateUserGlobalData` ([≈07:05:26](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=25526s))

Loops over every reserve and adds up the user's position in ETH.

```solidity
function calculateUserGlobalData(address user) public view returns (
    uint256 totalLiquidityBalanceETH,
    uint256 totalCollateralBalanceETH,
    uint256 totalBorrowBalanceETH,
    uint256 totalFeesETH,
    uint256 currentLtv,
    uint256 currentLiquidationThreshold,
    uint256 healthFactor,
    bool healthFactorBelowThreshold
) {
    IPriceOracleGetter oracle = IPriceOracleGetter(i_addressesProvider.getPriceOracle());
    UserGlobalDataLocalVars memory vars;
    address[] memory reserves = i_core.getReserves();

    for (uint256 i = 0; i < reserves.length; i++) {
        vars.currentReserve = reserves[i];

        (vars.compoundedLiquidityBalance, vars.compoundedBorrowBalance, vars.originationFee,
         vars.userUsesReserveAsCollateral) = i_core.getUserBasicReserveData(vars.currentReserve, user);

        // user neither supplied nor borrowed this asset → skip
        if (vars.compoundedLiquidityBalance == 0 && vars.compoundedBorrowBalance == 0) continue;

        (vars.reserveDecimals, vars.baseLtv, vars.liquidationThreshold, vars.usageAsCollateralEnabled)
            = i_core.getReserveConfiguration(vars.currentReserve);

        vars.tokenUnit = 10 ** vars.reserveDecimals;
        vars.reserveUnitPrice = oracle.getAssetPrice(vars.currentReserve);

        if (vars.compoundedLiquidityBalance > 0) {
            uint256 liquidityBalanceETH =
                (vars.reserveUnitPrice * vars.compoundedLiquidityBalance) / vars.tokenUnit;
            totalLiquidityBalanceETH += liquidityBalanceETH;

            // counts as collateral only if BOTH the reserve allows it AND the user turned it on
            if (vars.usageAsCollateralEnabled && vars.userUsesReserveAsCollateral) {
                totalCollateralBalanceETH += liquidityBalanceETH;
                currentLtv += liquidityBalanceETH * vars.baseLtv;                       // weighted sum
                currentLiquidationThreshold += liquidityBalanceETH * vars.liquidationThreshold;
            }
        }

        if (vars.compoundedBorrowBalance > 0) {
            totalBorrowBalanceETH += (vars.reserveUnitPrice * vars.compoundedBorrowBalance) / vars.tokenUnit;
            totalFeesETH += (vars.originationFee * vars.reserveUnitPrice) / vars.tokenUnit;
        }
    }

    // turn the weighted sums into weighted averages
    currentLtv = totalCollateralBalanceETH > 0 ? currentLtv / totalCollateralBalanceETH : 0;
    currentLiquidationThreshold =
        totalCollateralBalanceETH > 0 ? currentLiquidationThreshold / totalCollateralBalanceETH : 0;

    healthFactor = _calculateHealthFactorFromBalances(
        totalCollateralBalanceETH, totalBorrowBalanceETH, totalFeesETH, currentLiquidationThreshold);
    healthFactorBelowThreshold = healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD;
}
```

**Weighted averages.** A user with several collateral assets has one LTV and one threshold, each weighted by how much ETH each asset is worth: `Σ(valueᵢ × LTᵢ) / Σ valueᵢ`.

**Liquidity vs collateral.** Every deposit adds to *total liquidity*. It only adds to *collateral* if both flags are true.

### Core helpers it needs

```solidity
// Everything the data provider needs for one user in one reserve
function getUserBasicReserveData(address reserve, address user)
    external view returns (uint256 underlyingBalance, uint256 compoundedBorrowBalance, uint256 originationFee, bool useAsCollateral)
{
    CoreLibrary.ReserveData storage r = s_reserves[reserve];
    CoreLibrary.UserReserveData storage u = s_usersReserveData[user][reserve];

    uint256 underlyingBalance = getUserUnderlyingAssetBalance(reserve, user);
    if (u.principalBorrowBalance == 0) return (underlyingBalance, 0, 0, u.useAsCollateral);
    return (underlyingBalance, u.getCompoundedBorrowBalance(r), u.originationFee, u.useAsCollateral);
}

// what you deposited plus interest = your aToken balance
function getUserUnderlyingAssetBalance(address reserve, address user) public view returns (uint256) {
    AToken aToken = AToken(s_reserves[reserve].aTokenAddress);
    return aToken.balanceOf(user);
}

function isUserUseReserveAsCollateralEnabled(address reserve, address user) external view returns (bool) {
    CoreLibrary.UserReserveData storage u = s_usersReserveData[user][reserve];
    return u.useAsCollateral;
}
```

**Origination fee**: a fee the protocol charges when you borrow. It counts as debt in the health factor.

### `getCompoundedBorrowBalance` (CoreLibrary) ([≈07:31:48](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=27108s))

How much a user's debt has grown since their last update. Aave V1 has two kinds of borrow (stable rate and variable rate), and a user has one or the other. Later Aave versions removed stable rate, but the instructor keeps it here because it's interesting.

```solidity
function getCompoundedBorrowBalance(UserReserveData storage self, ReserveData storage reserve)
    internal view returns (uint256)
{
    if (self.principalBorrowBalance == 0) return 0;

    uint256 principalBorrowBalanceRay = self.principalBorrowBalance.wadToRay();
    uint256 compoundedBalance = 0;
    uint256 cumulatedInterest = 0; // really a growth factor

    if (self.stableBorrowRate > 0) {
        // STABLE: compound the user's own fixed rate since the user's last update
        cumulatedInterest = calculateCompoundedInterest(self.stableBorrowRate, self.lastUpdateTimestamp);
    } else {
        // VARIABLE: bring the reserve index up to now, then divide by the user's checkpoint
        cumulatedInterest = calculateCompoundedInterest(reserve.currentVariableBorrowRate, reserve.lastUpdateTimestamp)
            .rayMul(reserve.lastVariableBorrowCumulativeIndex)
            .rayDiv(self.lastVariableBorrowCumulativeIndex);
    }

    compoundedBalance = principalBorrowBalanceRay.rayMul(cumulatedInterest).rayToWad();

    // Time passed but rounding left the debt unchanged → add 1 wei so a loan is never interest-free
    if (compoundedBalance == self.principalBorrowBalance) {
        if (self.lastUpdateTimestamp != block.timestamp) return self.principalBorrowBalance + 1 wei;
    }
    return compoundedBalance;
}
```

- **Stable**: every user can have a different rate, so the growth comes only from *the user's* rate.
- **Variable**: this is the index method from [05](05-index-based-accounting.md): current reserve index / user's index.

**Tests**: no debt → 0 · stable: 1,000 principal, 1 year → principal × compounded(stable rate) · variable, no time passed: reserve index 1.10 / user 1.00 → 100 → **110** · variable with time: reserve index 1.05, 10% rate, 1 year, user index 1 → ≈ **116** · rounding case: principal 1 wei, time passed, no visible growth → **2 wei**.

### `calculateUserGlobalData` tests
- Reserve set up but the user has no balances → skipped, all zeros.
- Two active reserves plus one empty one → totals are the sum of the two. LTV and threshold are weighted by collateral value. The empty reserve's 90 LTV, 95 LT and price have no effect.
- Collateral needs both flags: with one false and one true, total liquidity is still the sum, but collateral = 0, LTV = 0, LT = 0.
- Undercollateralized user → HF 0.4 → `healthFactorBelowThreshold = true`.

## `balanceDecreaseAllowed` ([≈08:25:18](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=30318s))

The question: **if the user removes `amount` of this asset, is their health factor still ≥ 1?**

```solidity
function balanceDecreaseAllowed(address reserve, address user, uint256 amount) external view returns (bool) {
    BalanceDecreaseAllowedLocalVars memory vars;

    (vars.decimals, , vars.reserveLiquidationThreshold, vars.reserveUsageAsCollateralEnabled)
        = i_core.getReserveConfiguration(reserve);

    // 1. Not used as collateral (by the reserve OR by the user) → nothing backs a loan → allowed
    if (!vars.reserveUsageAsCollateralEnabled || !i_core.isUserUseReserveAsCollateralEnabled(reserve, user)) {
        return true;
    }

    // 2. Read the user's global position
    (, vars.collateralBalanceETH, vars.borrowBalanceETH, vars.totalFeesETH, ,
     vars.currentLiquidationThreshold, , ) = calculateUserGlobalData(user);

    // 3. No debt → no liquidation risk → allowed
    if (vars.borrowBalanceETH == 0) return true;

    // 4. Convert the decrease to ETH
    IPriceOracleGetter oracle = IPriceOracleGetter(i_addressesProvider.getPriceOracle());
    vars.amountToDecreaseETH = (oracle.getAssetPrice(reserve) * amount) / (10 ** vars.decimals);

    // 5. Collateral after the decrease; with debt you can't go to zero collateral
    vars.collateralBalanceAfterDecrease = vars.collateralBalanceETH - vars.amountToDecreaseETH;
    if (vars.collateralBalanceAfterDecrease == 0) return false;

    // 6. Recalculate the weighted liquidation threshold without the removed collateral
    vars.liquidationThresholdAfterDecrease = (
        vars.collateralBalanceETH * vars.currentLiquidationThreshold
            - vars.amountToDecreaseETH * vars.reserveLiquidationThreshold
    ) / vars.collateralBalanceAfterDecrease;

    // 7. New health factor must stay above 1
    uint256 healthFactorAfterDecrease = _calculateHealthFactorFromBalances(
        vars.collateralBalanceAfterDecrease, vars.borrowBalanceETH, vars.totalFeesETH,
        vars.liquidationThresholdAfterDecrease);

    return healthFactorAfterDecrease > HEALTH_FACTOR_LIQUIDATION_THRESHOLD;
}
```

**Why recalculate the threshold (step 6)?** Example from the video: 1 ETH worth of DAI (LT 80) + 1 ETH worth of WETH (LT 85) → weighted LT = 82.5. Remove 0.5 ETH worth of DAI → (0.5 × 80 + 1 × 85) / 1.5 = **83.33**. Removing an asset changes the mix, so the threshold moves.

Oracle conversion example: 100 DAI at 0.0005 ETH = **0.05 ETH**.

**Tests**
- Allowed: collateral 1 ETH (100 tokens), borrow 0.5 ETH, LT 80, decrease 10 tokens (0.1 ETH) → collateral 0.9, LT stays 80, HF = 0.9 × 0.8 / 0.5 = **1.44** → `true`.
- Not allowed: the decrease brings HF to **0.96** → `false`.

## Recap

The data provider changes nothing. It prices every reserve in ETH, adds up liquidity, collateral (only when both flags are on), debt and fees, weights LTV and LT by collateral value, and calculates the health factor. Redeem uses `balanceDecreaseAllowed` to block withdrawals that would make a position liquidatable.
