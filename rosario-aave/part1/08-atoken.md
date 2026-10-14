# 8. AToken

▶ [Watch from 03:39:52](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=14392s) · Previous: [07](07-lending-pool.md) · Next: [09 Redeem](09-redeem.md)

## What it is

An **interest-bearing ERC20** that represents a user's deposit in one reserve. Each aToken maps to **one** underlying asset (aDAI ↔ DAI, aUSDC ↔ USDC). The reserve's `ReserveData.aTokenAddress` points to it.

The underlying DAI is **held by LendingPoolCore**, not by the aToken. The aToken is only the receipt.

> Deposit 100 DAI → you get 100 aDAI.
> One year at 5%, with the liquidity index going from 1.00 to 1.05 → `balanceOf` = 100 × 1.05 / 1.00 = **105 aDAI**.
> Redeem all → you get **105 DAI**.

The instructor calls this the cleverest part of Aave's design: the receipt token itself shows the interest earned.

### Responsibilities
1. Mint aTokens on deposit.
2. Track each user's index checkpoint.
3. Calculate the current balance including interest.
4. Turn earned interest into real minted tokens ("materialize" it) whenever state changes.
5. Redeem aTokens for the underlying asset ([09](09-redeem.md)).
6. Block balance decreases that would make a borrow position unsafe.
7. Clear user data after a full redeem.
8. Move or burn aTokens when collateral is liquidated (Part 2).

## State and constructor ([≈03:54:58](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=14098s))

```solidity
contract AToken is ERC20 {
    using WadRayMath for uint256;

    uint256 public constant UINT_MAX_VALUE = type(uint256).max;

    address private immutable i_underlyingAssetAddress;
    uint8 private immutable i_underlyingAssetDecimals;   // not every ERC20 has 18 decimals (USDC = 6)

    // last reserve normalized income already applied to each user
    mapping(address user => uint256 lastNormalizedIncome) internal s_userIndexes;

    LendingPoolAddressesProvider private immutable i_addressesProvider;
    LendingPoolCore private immutable i_core;
    LendingPool private immutable i_pool;

    constructor(
        address addressesProvider,
        address underlyingAsset,
        uint8 underlyingAssetDecimals,
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {
        if (underlyingAsset == address(0) || addressesProvider == address(0)) revert AToken__ZeroAddress();
        i_underlyingAssetDecimals = underlyingAssetDecimals;
        i_addressesProvider = LendingPoolAddressesProvider(addressesProvider);

        address coreAddress = i_addressesProvider.getLendingPoolCore();
        address poolAddress = i_addressesProvider.getLendingPool();
        if (coreAddress == address(0) || poolAddress == address(0)) revert AToken__ZeroAddress();

        i_core = LendingPoolCore(coreAddress);
        i_pool = LendingPool(poolAddress);
        i_underlyingAssetAddress = underlyingAsset;
    }
```

A `LENDING_POOL` key, setter, event and getter is added to the addresses provider.

## Glossary for this chapter
- **Principal balance**: the plain ERC20 balance (`super.balanceOf`): aTokens minted minus burned. It doesn't include interest that hasn't been minted yet.
- **User index** (`s_userIndexes[user]`): the reserve's normalized income the last time interest was turned into minted tokens for this user. It's updated on deposit, redeem, transfer and liquidation.
- **Reserve normalized income**: the live liquidity index from `core.getReserveNormalizedIncome(asset)`. It's the stored index × linear interest since the last update.

## `calculateCumulatedBalance` ([≈04:09:53](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=14993s))

**currentBalance = principal × currentNormalizedIncome / userIndex**

```solidity
function _calculateCumulatedBalance(address user, uint256 balance) internal view returns (uint256) {
    return balance
        .wadToRay()
        .rayMul(i_core.getReserveNormalizedIncome(i_underlyingAssetAddress))
        .rayDiv(s_userIndexes[user])
        .rayToWad();
}
```

The core getter it needs:

```solidity
function getReserveNormalizedIncome(address reserve) external view returns (uint256) {
    CoreLibrary.ReserveData storage r = s_reserves[reserve];
    return r.getNormalizedIncome();
}
```

**Tests** (mock core with `setReserveNormalizedIncome`):

| User index | Reserve income | Principal | Result |
|---|---|---|---|
| 1.00 | 1.05 | 100 | 105 |
| 1.00 | 1.00 | 100 | 100 (no interest) |
| 1.05 | 1.10 | 100 | ≈ 104.76 (only the growth *since* the user's checkpoint) |

## `balanceOf` (override)

```solidity
function balanceOf(address user) public view override returns (uint256) {
    uint256 currentPrincipalBalance = super.balanceOf(user);
    if (currentPrincipalBalance == 0) return 0;
    return _calculateCumulatedBalance(user, currentPrincipalBalance);
}
```

Tests: zero principal → 0 · index 1 / income 1 → 100 · index 1 / income 1.05 → 105.

## `totalSupply` (override) ([≈04:34:29](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=16469s))

```solidity
function totalSupply() public view override returns (uint256) {
    uint256 currentSupplyPrincipal = super.totalSupply();
    if (currentSupplyPrincipal == 0) return 0;
    return currentSupplyPrincipal
        .wadToRay()
        .rayMul(i_core.getReserveNormalizedIncome(i_underlyingAssetAddress))
        .rayToWad();
}
```

There's **no division by a user index** here, because this is the reserve-wide total, not one user's share.

Tests: no principal → 0 · 140 principal (100 + 40 from two users) at income 1 → 140 · at income 1.05 → **147**.

## `cumulateBalance`: turn earned interest into real tokens ([≈04:40:17](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=16817s))

```solidity
function _cumulateBalance(address user)
    internal
    returns (uint256 previousPrincipal, uint256 newPrincipal, uint256 balanceIncrease, uint256 index)
{
    uint256 previousPrincipalBalance = super.balanceOf(user);
    balanceIncrease = balanceOf(user) - previousPrincipalBalance;   // interest earned since last checkpoint

    _mint(user, balanceIncrease);                                   // interest → principal

    // move the checkpoint forward so the same interest isn't counted twice
    index = s_userIndexes[user] = i_core.getReserveNormalizedIncome(i_underlyingAssetAddress);

    return (previousPrincipalBalance, previousPrincipalBalance + balanceIncrease, balanceIncrease, index);
}
```

Each time the principal changes, the user index has to move to the current normalized income. The user index means "interest has been minted up to here."

Tests: index 1 / income 1 → mints 0, index stays 1 · index 1 / income 1.05, principal 100 → mints **5**, new principal 105, index becomes 1.05.

A `getUserIndex(address)` getter is added, because the mapping is `internal`.

## `mintOnDeposit` ([≈04:53:29](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=17609s))

```solidity
modifier onlyLendingPool() {
    if (msg.sender != address(i_pool)) revert AToken__OnlyLendingPool();
    _;
}

function mintOnDeposit(address account, uint256 amount) external onlyLendingPool {
    (, , uint256 balanceIncrease, uint256 index) = _cumulateBalance(account); // 1. mint earned interest + checkpoint
    _mint(account, amount);                                                   // 2. mint the new deposit 1:1
    emit MintOnDeposit(account, amount, balanceIncrease, index);
}
```

**Tests**
- Called by anyone other than the pool → reverts. Tests use `vm.prank(pool)`.
- **First deposit when the reserve income is already 1.05**: the user earns nothing for the time before they joined. Interest = 0, index set to 1.05, balance = deposit.
- **Existing 100 principal at index 1, income now 1.05, deposit 20**: mints 5 interest, then 20. Principal = **125**, index = 1.05.

The rest of the deposit flow is in [07, section "Finishing deposit()"](07-lending-pool.md).
