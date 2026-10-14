# 6. Deposit: overview

▶ [Watch from 03:14:08](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=11648s) · Previous: [05](05-index-based-accounting.md) · Next: [07 LendingPool](07-lending-pool.md)

A one-minute chapter that frames the deposit flow:

```
user ──deposit(DAI, 100)──► LendingPool
                               │
                               ├─► LendingPoolCore: update indexes and rates, pull 100 DAI in
                               │
                               └─► AToken (aDAI): mint 100 aDAI to the user
```

- The user deposits an ERC20 (e.g. DAI) or ETH through the **LendingPool**.
- The pool tells the **AToken** to **mint** aTokens (aDAI) to the user. They are the deposit receipt.
- aTokens **grow in value** over time because their balance includes the interest earned.
- The deposited DAI itself sits in the **LendingPoolCore**.

The code is in [07 LendingPool](07-lending-pool.md) and [08 AToken](08-atoken.md).
