# 7. LendingPool and the deposit flow

▶ [Watch from 03:15:15](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=11715s) · Previous: [06](06-deposit-overview.md) · Next: [08 AToken](08-atoken.md)

This chapter starts `deposit()`. Partway through, the video stops to build the AToken ([08](08-atoken.md)), then comes back. The rest of `deposit()` and its core functions are at the end of this file, from **05:05:18** onward.

## Contract skeleton

```solidity
contract LendingPool is ReentrancyGuard {
    LendingPoolAddressesProvider private s_addressesProvider; // NOT immutable, see below
    LendingPoolCore private s_core;

    constructor(address addressesProvider) {
        if (addressesProvider == address(0)) revert LendingPool__ZeroAddress();
        s_addressesProvider = LendingPoolAddressesProvider(addressesProvider);
        address coreAddress = s_addressesProvider.getLendingPoolCore();
        if (coreAddress == address(0)) revert LendingPool__ZeroAddress();
        s_core = LendingPoolCore(coreAddress);
    }
```

### Why regular storage and not `immutable`? ([≈03:22:00](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=12120s))
Later the pool will `delegatecall` the **LiquidationManager**. With delegatecall, the called code runs on the **caller's storage**, so both contracts need the same storage layout. Immutables are part of the bytecode, not storage. So these must be ordinary state variables, in the same order in both contracts.

The provider gets a `LENDING_POOL_CORE` key with a setter, event and getter, like the configurator in [04](04-lending-pool-core.md).

## Modifiers

```solidity
modifier onlyActiveReserve(address reserve) {
    if (!s_core.getReserveIsActive(reserve)) revert LendingPool__ReserveIsNotActive();
    _;
}
modifier onlyUnfreezedReserve(address reserve) {
    if (s_core.getReserveIsFreezed(reserve)) revert LendingPool__ReserveIsFrozen();
    _;
}
modifier onlyAmountGreaterThanZero(uint256 amount) {
    if (amount == 0) revert LendingPool__AmountIsZero();
    _;
}
```

The core needs simple getters, which all follow the same pattern:

```solidity
function getReserveIsActive(address reserve) external view returns (bool) {
    CoreLibrary.ReserveData storage r = s_reserves[reserve];
    return r.isActive;
}
// getReserveIsFreezed, getReserveATokenAddress, getReserveConfiguration … same shape
```

## The deposit steps

```solidity
function deposit(address reserve, uint256 amount, uint16 referralCode)
    external payable nonReentrant
    onlyActiveReserve(reserve) onlyUnfreezedReserve(reserve) onlyAmountGreaterThanZero(amount)
{
    // 1. Find the aToken for this reserve (DAI → aDAI)
    // 2. Is this the user's first deposit in this reserve?
    // 3. Update reserve and user state BEFORE minting
    // 4. Mint aTokens 1:1 to the user
    // 5. Pull the funds (ERC20 or ETH) from the user into the core
    // 6. Emit Deposit
}
```

`payable` because the reserve can be ETH. `referralCode` is kept for compatibility but never used.

---

## Finishing `deposit()` (after the AToken chapter) ([≈05:05:18](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=18318s))

```solidity
    AToken aToken = AToken(s_core.getReserveATokenAddress(reserve));
    bool isFirstDeposit = aToken.balanceOf(msg.sender) == 0;

    s_core.updateStateOnDeposit(reserve, msg.sender, amount, isFirstDeposit);
    aToken.mintOnDeposit(msg.sender, amount);
    s_core.transferToReserve{value: msg.value}(reserve, payable(msg.sender), amount);

    emit Deposit(reserve, msg.sender, amount, referralCode, block.timestamp);
}
```

### `updateStateOnDeposit` (core, `onlyLendingPool`) ([≈05:09:17](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=18557s))

```solidity
function updateStateOnDeposit(address reserve, address user, uint256 amount, bool isFirstDeposit)
    external onlyLendingPool
{
    // a) Move the indexes forward using the OLD (pre-deposit) rates
    s_reserves[reserve].updateCumulativeIndexes();
    // b) Calculate and store the NEW rates now that liquidity went up
    _updateReserveInterestRatesAndTimestamp(reserve, amount, 0);
    // c) First deposit → turn on "use as collateral" for this user
    if (isFirstDeposit) setUserUseReserveAsCollateral(reserve, user, true);
}
```

Order matters: first settle the interest earned at the old rate, then set the new rate.

### `_updateReserveInterestRatesAndTimestamp` ([≈05:17:18](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=19038s))

One function used by every flow:
- `liquidityAdded`: from **deposit** or **repay**
- `liquidityTaken`: from **redeem** or **borrow**

```solidity
function _updateReserveInterestRatesAndTimestamp(address reserve, uint256 liquidityAdded, uint256 liquidityTaken)
    internal
{
    CoreLibrary.ReserveData storage r = s_reserves[reserve];

    (uint256 newLiquidityRate, uint256 newStableRate, uint256 newVariableRate) =
        IReserveInterestRateStrategy(r.interestRateStrategyAddress).calculateInterestRates(
            reserve,
            getReserveAvailableLiquidity(reserve) + liquidityAdded - liquidityTaken,
            r.totalBorrowsStable,
            r.totalBorrowsVariable,
            r.currentAverageStableBorrowRate
        );

    r.currentLiquidityRate = newLiquidityRate;
    r.currentStableBorrowRate = newStableRate;
    r.currentVariableBorrowRate = newVariableRate;
    r.lastUpdateTimestamp = uint40(block.timestamp);

    emit ReserveUpdated(reserve, newLiquidityRate, newStableRate, newVariableRate,
        r.lastLiquidityCumulativeIndex, r.lastVariableBorrowCumulativeIndex);
}
```

### The interest rate strategy (behind an interface)

The core only knows the interface, so the rate model can be swapped later:

```solidity
interface IReserveInterestRateStrategy {
    function getBaseVariableBorrowRate() external view returns (uint256);
    function calculateInterestRates(
        address reserve,
        uint256 availableLiquidity,
        uint256 totalBorrowsStable,
        uint256 totalBorrowsVariable,
        uint256 averageStableBorrowRate
    ) external view returns (uint256 liquidityRate, uint256 stableBorrowRate, uint256 variableBorrowRate);
}
```

How the rates are set (more detail later in the series):
- Rates depend on **utilization**: `U = totalBorrows / (availableLiquidity + totalBorrows)`.
- Rates rise slowly up to an optimal U (about 80%), then **rise steeply** above it.
- The borrow rate is always above the deposit rate, because borrowers pay the depositors.

Tests use a `MockInterestRateStrategy` whose rates you set directly.

### Available liquidity = the core's balance

```solidity
function getReserveAvailableLiquidity(address reserve) public view returns (uint256) {
    uint256 balance = 0;
    if (reserve == EthAddressLib.ethAddress()) {
        balance = address(this).balance;
    } else {
        balance = IERC20(reserve).balanceOf(address(this));
    }
    return balance;
}
```

`EthAddressLib.ethAddress()` returns the placeholder `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`. By convention it stands for native ETH. No contract lives there.

### Collateral flag setter

```solidity
function setUserUseReserveAsCollateral(address reserve, address user, bool useAsCollateral)
    public onlyLendingPool
{
    CoreLibrary.UserReserveData storage u = s_usersReserveData[user][reserve];
    u.useAsCollateral = useAsCollateral;
}
```

`onlyLendingPool` on the core checks `msg.sender == i_addressesProvider.getLendingPool()`.

### `transferToReserve`: pull the funds in ([≈05:58:33](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=21513s))

```solidity
using SafeERC20 for IERC20;

function transferToReserve(address reserve, address payable user, uint256 amount)
    external payable onlyLendingPool
{
    if (reserve != EthAddressLib.ethAddress()) {
        if (msg.value != 0) revert LendingPoolCore__CannotSendEthWithErc20Transfer();
        IERC20(reserve).safeTransferFrom(user, address(this), amount); // user must approve first
    } else {
        if (msg.value < amount) revert LendingPoolCore__MsgValueLessThanAmount();
        if (msg.value > amount) {
            uint256 excess = msg.value - amount;            // refund extra ETH
            (bool ok, ) = user.call{value: excess}("");
            if (!ok) revert LendingPoolCore__EthTransferFailed(user, excess);
        }
    }
}
```

Why `SafeERC20`: a plain `transfer`/`transferFrom` returns a `bool` that you have to check yourself, and some tokens return nothing at all. `safeTransferFrom` reverts on failure either way. The instructor first wrote `safeTransfer` by mistake. It has to be `safeTransferFrom`, because the money moves **from the user** to the core.

## Integration tests (`LendingPoolIntegrationTest`) ([≈06:12:01](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=22321s))

The setup deploys the addresses provider, core, pool, DAI, aDAI and a mock rate strategy, initializes the DAI reserve, and mints 100 DAI to the user.

**Basic deposit of 100 DAI** (after `dai.approve(core, 100)`):

| Check | Before | After |
|---|---|---|
| user DAI | 100 | 0 |
| core DAI | 0 | 100 |
| user aDAI | 0 | 100 |
| user index | n/a | 1 ray |
| `getReserveAvailableLiquidity` | 0 | 100 |
| `useAsCollateral` | false | true |

Other tests: reverts if the reserve is inactive or frozen · two deposits add up · interest already earned is minted before the second deposit · can't send ETH with an ERC20 deposit · reverts if the user's balance is too low.

## Recap

Deposit = settle the indexes at the old rates → set new rates and timestamp → enable collateral on first deposit → mint aTokens (after minting any interest already owed) → pull the funds into the core.
