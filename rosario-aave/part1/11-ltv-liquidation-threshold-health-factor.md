# 11. LTV, liquidation threshold, health factor

▶ [Watch from 06:46:19](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=24379s) (concepts run to ≈06:55:44) · Previous: [10](10-lending-pool-data-provider.md)

These are the risk ideas behind borrowing and liquidation. Part 2 covers them in depth. They come up here because the data provider's code uses them.

The rest of the video's chapter 11 (about 06:55 to 09:30) is code. It's in [10 Data provider](10-lending-pool-data-provider.md) and [09 Redeem](09-redeem.md).

## Aave is overcollateralized

You always have to deposit **more value than you borrow**. The protocol sets how much more for each asset.

## Loan to value (LTV): how much you can borrow

**LTV = debt / collateral.** The reserve's LTV setting is the **maximum** you may borrow against that collateral.

> 10 ETH of collateral × 75% LTV → you can borrow at most **7.5 ETH** worth.

## Liquidation threshold (LT): when you can be liquidated

The ratio at which a position becomes **liquidatable**.

> Start: collateral 10 ETH, debt 7.5 ETH → debt/collateral = 75%. LT = 80% → **safe**.
> The collateral's price falls 10% → collateral worth 9 ETH, debt still 7.5 → 83.3% > 80% → **liquidatable**.

Prices moving, whether collateral falls or the borrowed asset rises, can make a position liquidatable without the user doing anything.

**Liquidation**: a third party (the liquidator) repays part of your debt and gets your collateral **at a discount** (the liquidation bonus). In V1 the liquidator could repay up to 50% of the debt. Later versions allow more.

## LTV vs liquidation threshold

| | Decides | 10 ETH example |
|---|---|---|
| **LTV** (75%) | how much you can borrow at the start | borrow up to 7.5 ETH |
| **LT** (80%) | when you become liquidatable | liquidatable once debt reaches 8 ETH-equivalent |

**LTV < LT** on purpose. The gap is a safety buffer, so normal price moves right after borrowing don't get you liquidated straight away.

## Health factor (HF): one number for safety

> **HF = (collateral × liquidationThreshold) / (debt + fees)**

| HF | Meaning |
|---|---|
| > 1 | safe |
| = 1 | right at the line, not liquidatable yet |
| < 1 | **liquidatable** |

Examples (LT 80%, debt 7.5 ETH):
- Collateral 10 ETH → 10 × 0.8 / 7.5 = 8 / 7.5 = **1.067** → safe.
- Collateral falls 10% to 9 ETH → 9 × 0.8 / 7.5 = 7.2 / 7.5 = **0.96** → liquidatable.

HF drops below 1 when **collateral value falls** or **debt grows** (interest, or the borrowed asset's price rising).

## In code

- `liquidationThreshold` and `baseLTVasCollateral` are stored as whole percentages (80, 75), so the code divides by 100.
- `HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18` (1.0 as a wad).
- No debt → HF = `type(uint256).max`.
- With several collateral assets, LTV and LT are **weighted averages** by each asset's ETH value. See `calculateUserGlobalData` in [10](10-lending-pool-data-provider.md).

## Recap

LTV caps borrowing. LT marks where liquidation starts. HF = collateral × LT / debt, and below 1 the position is liquidatable. Keeping LTV below LT gives a buffer for price swings.
