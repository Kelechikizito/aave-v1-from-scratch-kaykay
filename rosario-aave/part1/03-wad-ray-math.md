# 3. WadRayMath library

▶ [Watch from 00:12:00](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=720s) · Previous: [02](02-project-setup.md) · Next: [04 LendingPoolCore](04-lending-pool-core.md)

## Why it exists

Solidity has no decimals, so values like `0.5`, `1.25`, `3.14` can't be stored directly. Aave stores them as large integers with a fixed number of implied decimals:

| Unit | Value | Decimals | Used for |
|---|---|---|---|
| **wad** | `1e18` | 18 | token amounts, percentages, general ratios |
| **ray** | `1e27` | 27 | interest rates and indexes (liquidity index, variable borrow index, normalized income), which need more precision |

Examples: `1e18` = 1.0 wad · `5e17` = 0.5 wad · `225e16` = 2.25 wad · `1e27` = 1.0 ray.

Relationship: **1 ray = 1 wad × 1e9** (`WAD_RAY_RATIO = 1e9`).

## Constants and getters

```solidity
library WadRayMath {
    error WadRayMath__DivisionByZero();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = WAD / 2;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = RAY / 2;
    uint256 internal constant WAD_RAY_RATIO = 1e9;

    function ray() internal pure returns (uint256) { return RAY; }
    function wad() internal pure returns (uint256) { return WAD; }
    function halfRay() internal pure returns (uint256) { return HALF_RAY; }
    function halfWad() internal pure returns (uint256) { return HALF_WAD; }
```

## Multiply and divide

Multiplying two wads gives 36 decimals, so divide by `WAD` to get back to 18. Adding **half a unit** before dividing **rounds half up** instead of always rounding down.

```solidity
    function wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + HALF_WAD) / WAD;
    }

    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert WadRayMath__DivisionByZero();
        return (a * WAD + b / 2) / b; // scale up first so the result keeps 18 decimals
    }

    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + HALF_RAY) / RAY;
    }

    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert WadRayMath__DivisionByZero();
        return (a * RAY + b / 2) / b;
    }
```

(In the video the instructor briefly says "ray" inside `wadDiv`; the wad version scales by `WAD`.)

### Why round half up: two examples worked through in the video

1. `wadMul(1 wei, 0.6e18)`: the exact answer is 0.6 wei.
   - Without `HALF_WAD`: `(1 × 6e17) / 1e18 = 0`, so the value is lost.
   - With `HALF_WAD`: `(6e17 + 5e17) / 1e18 = 1`, which rounds to the nearest whole number.
2. `wadDiv(2e18, 3e18)` = 0.6666…
   - Without rounding the result ends in `…666`.
   - With `+ b/2` it ends in `…667`.

These errors are tiny, but they matter for small amounts and percentages.

## Converting between ray and wad

```solidity
    function rayToWad(uint256 a) internal pure returns (uint256) {
        return (a + WAD_RAY_RATIO / 2) / WAD_RAY_RATIO; // round half up
    }

    function wadToRay(uint256 a) internal pure returns (uint256) {
        return a * WAD_RAY_RATIO; // just add 9 zeros
    }
```

## `rayPow`: ray to an integer power

Exponentiation by squaring: square the base each step and multiply it into the result when the current bit of `n` is 1. It takes O(log n) steps.

```solidity
    function rayPow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        z = n % 2 != 0 ? x : RAY;
        for (n /= 2; n != 0; n /= 2) {
            x = rayMul(x, x);
            if (n % 2 != 0) z = rayMul(z, x);
        }
    }
}
```

It's used for compound interest: `(1 + ratePerSecond) ^ seconds`.

In the video a typo in this loop broke the `2^3` test, and the unit test caught it. This is why the instructor writes unit tests.

## Tests ([≈00:23:00](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=1380s))

`test/unit/libraries/WadRayMathUnitTest.t.sol`, with a `WadRayMathHarness` that exposes each internal function as `external pure`.

| Test | Input | Expected |
|---|---|---|
| `wadMul` | 2 × 3 → `wadMul(2e18, 3e18)` | `6e18` |
| `wadMul` | 1.5 × 2 → `wadMul(15e17, 2e18)` | `3e18` |
| `wadDiv` | 3 / 2 → `wadDiv(3e18, 2e18)` | `15e17` |
| `rayToWad` | `1e27`, `5e27` | `1e18`, `5e18` |
| `rayPow` | `rayPow(5e27, 0)` | `1e27` (anything^0 = 1) |
| `rayPow` | `rayPow(1e27, 100)` | `1e27` (1^n = 1) |
| `rayPow` | `rayPow(2e27, 3)` | `8e27` |

Run one test: `forge test --mt test_WadMul -vvv`. Test functions that call the harness need `view`, because they read the harness address from storage.

## Recap

- wad = 18 decimals, ray = 27 decimals, ray = wad × 1e9.
- Multiply then divide by the unit; add half a unit to round half up.
- `rayPow` is the building block for compound interest.
