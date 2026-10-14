# 2. Repay

▶ [Watch from 03:08:52](https://www.youtube.com/watch?v=aq2cMmibayI&t=11332s) · Previous: [01 Borrow](01-borrow.md) · Next: [03 Liquidation](03-liquidation.md)

## The rule: the fee is paid first

Alice owes 100 DAI principal + 3 DAI interest + 1 DAI origination fee. She repays 40 DAI:
1. **1 DAI goes to the fee** → fee = 0.
2. **39 DAI goes to the debt** → 103 − 39 = **64 DAI** left.

If the payment is **≤ the outstanding fee**, it only reduces the fee and the debt doesn't change.

## `LendingPool.repay` ([03:10:41](https://www.youtube.com/watch?v=aq2cMmibayI&t=11441s))

`onBehalfOf` lets you repay someone else's loan.

```solidity
function repay(address reserve, uint256 amount, address payable onBehalfOf)
    external payable nonReentrant onlyActiveReserve(reserve) onlyAmountGreaterThanZero(amount)
{
    RepayLocalVars memory vars;

    // 1. Current debt position
    (vars.principalBorrowBalance,     // debt before newly accrued interest
     vars.compoundedBorrowBalance,    // total debt including interest
     vars.borrowBalanceIncrease)      // interest since last update
        = s_core.getUserBorrowBalances(reserve, onBehalfOf);

    // 2. Outstanding origination fee
    vars.originationFee = s_core.getUserOriginationFee(reserve, onBehalfOf);
    vars.isETH = EthAddressLib.ethAddress() == reserve;

    // 3. Nothing to repay?
    if (vars.compoundedBorrowBalance == 0) revert LendingPool__UserDoesNotHaveAnyBorrow();

    // 4. "Repay everything" (max) only for your own loan
    if (amount == type(uint256).max && msg.sender != onBehalfOf) {
        revert LendingPool__ExplicitAmountRequiredToRepayOnBehalf();
    }

    // 5. Default: everything = debt + fee. Partial if a smaller amount is given
    vars.paybackAmount = vars.compoundedBorrowBalance + vars.originationFee;
    if (amount != type(uint256).max && amount < vars.paybackAmount) vars.paybackAmount = amount;

    // 6. ETH repayments must send enough ETH
    if (vars.isETH && msg.value < vars.paybackAmount) revert LendingPool__InvalidRepaymentAmount();

    // 7. Payment only covers (part of) the fee → reduce the fee, the debt stays the same
    if (vars.paybackAmount <= vars.originationFee) {
        s_core.updateStateOnRepay(reserve, onBehalfOf, 0, vars.paybackAmount, vars.borrowBalanceIncrease, false);
        s_core.transferToFeeCollectionAddress{value: vars.isETH ? vars.paybackAmount : 0}(
            reserve, msg.sender, vars.paybackAmount, s_addressesProvider.getTokenDistributor());
        emit Repay(reserve, onBehalfOf, msg.sender, 0, vars.paybackAmount, vars.borrowBalanceIncrease, block.timestamp);
        return;
    }

    // 8. Fee fully covered; the rest pays down the debt
    vars.paybackAmountMinusFees = vars.paybackAmount - vars.originationFee;

    s_core.updateStateOnRepay(
        reserve, onBehalfOf, vars.paybackAmountMinusFees, vars.originationFee, vars.borrowBalanceIncrease,
        vars.compoundedBorrowBalance == vars.paybackAmountMinusFees // repaid the whole loan?
    );

    // 9. Fee → fee collector
    if (vars.originationFee > 0) {
        s_core.transferToFeeCollectionAddress{value: vars.isETH ? vars.originationFee : 0}(
            reserve, msg.sender, vars.originationFee, s_addressesProvider.getTokenDistributor());
    }

    // 10. Debt portion → back into the reserve
    s_core.transferToReserve{value: vars.isETH ? msg.value - vars.originationFee : 0}(
        reserve, payable(msg.sender), vars.paybackAmountMinusFees);

    emit Repay(reserve, onBehalfOf, msg.sender, vars.paybackAmountMinusFees, vars.originationFee,
        vars.borrowBalanceIncrease, block.timestamp);
}
```

## Core: `updateStateOnRepay` ([03:30:44](https://www.youtube.com/watch?v=aq2cMmibayI&t=12644s))

```solidity
function updateStateOnRepay(address reserve, address user, uint256 paybackAmountMinusFees,
    uint256 originationFeeRepaid, uint256 balanceIncrease, bool repaidWholeLoan) external onlyLendingPool
{
    _updateReserveStateOnRepay(reserve, user, paybackAmountMinusFees, balanceIncrease);   // 1. reserve totals
    _updateUserStateOnRepay(reserve, user, paybackAmountMinusFees, originationFeeRepaid,
        balanceIncrease, repaidWholeLoan);                                                 // 2. user record
    _updateReserveInterestRatesAndTimestamp(reserve, paybackAmountMinusFees, 0);          // 3. liquidity ADDED
}
```

The reserve is updated **before** the user. The reserve step reads the user's current rate mode and stable rate, and the user step may clear them.

### Reserve side ([03:33:24](https://www.youtube.com/watch?v=aq2cMmibayI&t=12804s))

**new total = old total + interest earned − amount repaid**, in whichever bucket the user is in:

```solidity
function _updateReserveStateOnRepay(address reserve, address user, uint256 paybackAmountMinusFees, uint256 balanceIncrease)
    internal
{
    CoreLibrary.ReserveData storage r = s_reserves[reserve];
    CoreLibrary.UserReserveData storage u = s_usersReserveData[user][reserve];
    CoreLibrary.InterestRateMode borrowRateMode = getUserCurrentBorrowRateMode(reserve, user);

    r.updateCumulativeIndexes();

    if (borrowRateMode == CoreLibrary.InterestRateMode.STABLE) {
        r.increaseTotalBorrowsStableAndUpdateAverageRate(balanceIncrease, u.stableBorrowRate);
        r.decreaseTotalBorrowsStableAndUpdateAverageRate(paybackAmountMinusFees, u.stableBorrowRate);
    } else {
        r.increaseTotalBorrowsVariable(balanceIncrease);
        r.decreaseTotalBorrowsVariable(paybackAmountMinusFees);
    }
}
```

Test (variable loan): variable 100 + interest 10 − repaid 30 = **80**. Stable 50 and the average are unchanged. Liquidity index → linear growth at 5%, variable index → compound growth at 10% over the year. Other tests: repaying the last stable loan clears both the stable total and the average · repaying more than is owed reverts (variable and stable).

### User side ([03:48:58](https://www.youtube.com/watch?v=aq2cMmibayI&t=13738s))

```solidity
function _updateUserStateOnRepay(address reserve, address user, uint256 paybackAmountMinusFees,
    uint256 originationFeeRepaid, uint256 balanceIncrease, bool repaidWholeLoan) internal
{
    CoreLibrary.ReserveData storage r = s_reserves[reserve];
    CoreLibrary.UserReserveData storage u = s_usersReserveData[user][reserve];

    // stored principal + interest earned − amount repaid
    u.principalBorrowBalance = u.principalBorrowBalance + balanceIncrease - paybackAmountMinusFees;
    u.lastVariableBorrowCumulativeIndex = r.lastVariableBorrowCumulativeIndex; // new checkpoint

    if (repaidWholeLoan) {       // no debt → clear the rate-mode fields
        u.stableBorrowRate = 0;
        u.lastVariableBorrowCumulativeIndex = 0;
    }

    u.originationFee = u.originationFee - originationFeeRepaid;
    u.lastUpdateTimestamp = uint40(block.timestamp);
}
```

Test: principal 100 at index 1.0, fee 5. The reserve index is now 1.2, repay 40, fee paid 2, interest 10 → principal **70**, fee **3**, index → 1.2, still variable (stable rate 0), collateral flag unchanged. Full repayment → principal 0, fee 0, both rate fields cleared. Repaying more than is owed → arithmetic panic.

**Combined `updateStateOnRepay` test**: reserve has 50 stable, 100 variable. User has 100 variable, fee 5, variable rate 5% → 7%, 1 day passes. Repay 40, fee 2, interest 10 → variable total **70**, stable 50, user principal 70, fee 3, new rates stored, timestamps updated.

## Core: `transferToFeeCollectionAddress` ([04:08:33](https://www.youtube.com/watch?v=aq2cMmibayI&t=14913s))

```solidity
function transferToFeeCollectionAddress(address token, address user, uint256 amount, address destination)
    external payable onlyLendingPool
{
    if (token != EthAddressLib.ethAddress()) {
        if (msg.value != 0) revert LendingPoolCore__CannotSendEthWithErc20Transfer();
        IERC20(token).safeTransferFrom(user, destination, amount);   // straight from the payer
    } else {
        if (msg.value < amount) revert LendingPoolCore__AmountAndValueSentDoNotMatch();
        (bool success, ) = destination.call{value: amount}("");
        if (!success) revert LendingPoolCore__EthTransferFailed(destination, amount);
    }
}
```

The **fee collector** is the "token distributor", a contract that collects protocol fees and pays them out. The addresses provider gets a `TOKEN_DISTRIBUTOR` key with a setter, event and getter.

## Integration test: full repay of a variable loan ([04:23:00](https://www.youtube.com/watch?v=aq2cMmibayI&t=15780s))

1. User deposits 100 DAI. User 2 deposits 1 WETH.
2. User borrows 0.02 WETH variable at 10%.
3. `vm.warp` 1 year → compounded debt > 0.02.
4. Mint the user the extra WETH needed for interest + fee, approve the core, then `repay(WETH, type(uint256).max, user)`.
5. Checks: principal = compounded = 0 · fee = 0 · rate mode = NONE · total variable = 0 · core WETH = original liquidity + interest (principal and interest returned) · the fee collector holds the borrow fee, which **doesn't** go into the pool's liquidity.

## Recap

Repay = work out debt and fee → fee first → if the payment only covers the fee, reduce the fee and stop → otherwise update the reserve totals (+interest, −repaid), the user record, then reprice (liquidity added) → fee to the collector, the rest to the reserve.
