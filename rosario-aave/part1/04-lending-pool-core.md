# 4. LendingPoolCore and CoreLibrary

▶ [Watch from 01:05:36](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=3936s) · Previous: [03](03-wad-ray-math.md) · Next: [05 Index-based accounting](05-index-based-accounting.md)

## What LendingPoolCore does

1. Stores **global data for every reserve**.
2. Stores **each user's data for every reserve**.
3. **Holds the deposited ERC20 tokens / ETH.**
4. Updates reserve **indexes and interest rates** whenever liquidity or borrows change.

## The two core mappings

```solidity
// asset (DAI, USDC…) → that reserve's global state
mapping(address asset => CoreLibrary.ReserveData) internal s_reserves;

// user → asset → that user's position in that reserve
mapping(address user => mapping(address reserve => CoreLibrary.UserReserveData)) internal s_usersReserveData;
```

- `s_reserves[DAI]` gives DAI's accounting.
- `s_usersReserveData[alice][USDC]` gives Alice's USDC position.

## CoreLibrary: structs and helper math

`src/libraries/CoreLibrary.sol` keeps reserve and user accounting logic **separate from the storage contract**. The structs (copied from Aave V1 in the video):

**`ReserveData`**: global accounting, configuration and rate state for one reserve:
- `lastLiquidityCumulativeIndex`: deposit (liquidity) index, ray
- `currentLiquidityRate`: deposit APR, ray
- `totalBorrowsStable`, `totalBorrowsVariable`
- `currentVariableBorrowRate`, `currentStableBorrowRate`, `currentAverageStableBorrowRate`
- `lastVariableBorrowCumulativeIndex`: variable debt index, ray
- `baseLTVasCollateral`, `liquidationThreshold`, `liquidationBonus`
- `decimals` (USDC = 6, most others = 18)
- `aTokenAddress`, `interestRateStrategyAddress`
- `lastUpdateTimestamp` (uint40)
- flags: `borrowingEnabled`, `usageAsCollateralEnabled`, `isStableBorrowRateEnabled`, `isActive`, `isFreezed`

**`UserReserveData`**: one user's borrow and collateral settings for one reserve:
- `principalBorrowBalance`
- `lastVariableBorrowCumulativeIndex`
- `originationFee` (fee charged when you borrow)
- `stableBorrowRate`
- `lastUpdateTimestamp`
- `useAsCollateral`

What CoreLibrary is responsible for: define both structs · initialize a reserve · update cumulative indexes · normalized income · linear interest · compound interest · total borrows · a user's compounded borrow balance · collateral/borrow switches · stable/variable totals.

## `init`: set up a reserve ([≈01:26:26](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=5186s))

```solidity
function init(
    ReserveData storage self,
    address aTokenAddress,
    uint256 decimals,
    address interestRateStrategyAddress
) external {
    if (self.aTokenAddress != address(0)) revert CoreLibrary__ReserveAlreadyInitialized();

    if (self.lastLiquidityCumulativeIndex == 0) {
        self.lastLiquidityCumulativeIndex = WadRayMath.ray(); // starts at 1.0
    }
    if (self.lastVariableBorrowCumulativeIndex == 0) {
        self.lastVariableBorrowCumulativeIndex = WadRayMath.ray(); // starts at 1.0
    }
    self.aTokenAddress = aTokenAddress;
    self.decimals = decimals;
    self.interestRateStrategyAddress = interestRateStrategyAddress;
    self.isActive = true;
    self.isFreezed = false;
}
```

Both indexes **start at 1 ray** and only grow:
- **liquidity index**: total interest earned by suppliers. 1.05 ray means deposits grew 5%.
- **variable borrow index**: total growth of variable debt. 1.08 ray means debt grew 8%.

The instructor notes that the original doesn't check the incoming `aTokenAddress` for zero.

## Linear interest (used for deposits) ([≈01:35:58](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=5758s))

**linearInterest = 1 + rate × (timePassed / SECONDS_PER_YEAR)**

| Rate | Time | Result |
|---|---|---|
| 5% | 0 | 1.0 |
| 5% | 1 year | 1.05 |
| 5% | ½ year | 1.025 |

```solidity
uint256 internal constant SECONDS_PER_YEAR = 365 days;

function calculateLinearInterest(uint256 rate, uint40 lastUpdateTimestamp) internal view returns (uint256) {
    uint256 timeDifference = block.timestamp - uint256(lastUpdateTimestamp);
    uint256 timeDelta = timeDifference.wadToRay().rayDiv(SECONDS_PER_YEAR.wadToRay()); // fraction of a year, ray
    return rate.rayMul(timeDelta) + WadRayMath.ray();
}
```

Needs `using WadRayMath for uint256;` so you can write `x.rayMul(y)`.

## Compound interest (used for borrows) ([≈01:48:23](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=6503s))

**compoundedInterest = (1 + ratePerSecond) ^ secondsPassed**, where ratePerSecond = annualRate / SECONDS_PER_YEAR.

At 5% for one year this is about 1.05127, a bit more than linear's 1.05, because interest earns interest.

```solidity
function calculateCompoundedInterest(uint256 rate, uint40 lastUpdateTimestamp) internal view returns (uint256) {
    uint256 timeDifference = block.timestamp - uint256(lastUpdateTimestamp);
    uint256 ratePerSecond = rate / SECONDS_PER_YEAR;
    return (ratePerSecond + WadRayMath.ray()).rayPow(timeDifference);
}
```

### Tests (`CoreLibraryUnitTest`)
- No time passed → both functions return exactly 1 ray.
- `vm.warp(block.timestamp + SECONDS_PER_YEAR)` at 5% → linear = `105e25`.
- Half a year → linear = `1025e24`.
- Compound after 1 month (`SECONDS_PER_YEAR / 12`) ≈ 1.0042; after 2 months ≈ 1.0084. The test recomputes `(RAY + rate/SECONDS_PER_YEAR).rayPow(t)` and compares.

The next chapter explains why deposits use linear interest and borrows use compound interest: [05](05-index-based-accounting.md).

---

## The reserves list ([≈02:35:52](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=9352s))

```solidity
address[] private s_reservesList;                      // every initialized reserve
mapping(address reserve => bool isAdded) private s_isReserveAdded;

function _addReserveToList(address reserve) internal {
    if (s_isReserveAdded[reserve]) return;
    s_reservesList.push(reserve);
    s_isReserveAdded[reserve] = true;
}

function getReserves() external view returns (address[] memory) {
    return s_reservesList;
}
```

### `removeLastAddedReserve` (configurator only)

Only removes the **last** reserve in the list, and only if nothing is borrowed from it.

```solidity
function removeLastAddedReserve(address reserveToRemove) external onlyLendingPoolConfigurator {
    uint256 len = s_reservesList.length;
    if (len == 0) revert LendingPoolCore__ReserveListIsEmpty();

    address lastReserve = s_reservesList[len - 1];
    if (lastReserve != reserveToRemove) revert LendingPoolCore__ReserveToRemoveIsNotLast();
    if (getReserveTotalBorrows(lastReserve) != 0) revert LendingPoolCore__ReserveHasBorrows();

    delete s_reserves[lastReserve];         // reset every field of the struct
    s_isReserveAdded[lastReserve] = false;
    s_reservesList.pop();
    emit ReserveRemoved(lastReserve);
}

function getReserveTotalBorrows(address reserve) public view returns (uint256) {
    return s_reserves[reserve].getTotalBorrows();
}
```

`getTotalBorrows` lives in CoreLibrary and returns `totalBorrowsStable + totalBorrowsVariable`. Calling it with dot syntax needs:

```solidity
using CoreLibrary for CoreLibrary.ReserveData;
using CoreLibrary for CoreLibrary.UserReserveData;
```

The real `LendingPoolConfigurator` has a function with the same name that forwards to the core.

## LendingPoolAddressesProvider: the address registry ([≈02:51:38](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=10298s))

Every contract asks this registry for the addresses of the others (pool, core, configurator, data provider, oracle…). Files go in `src/configuration/`.

```solidity
contract AddressStorage {
    error AddressStorage__ZeroAddress();
    mapping(bytes32 => address) private addresses;

    function getAddress(bytes32 key) public view returns (address) {
        return addresses[key];
    }

    function _setAddress(bytes32 key, address value) internal {
        if (value == address(0)) revert AddressStorage__ZeroAddress();
        addresses[key] = value;
    }
}

contract LendingPoolAddressesProvider is Ownable, AddressStorage {
    bytes32 private constant LENDING_POOL_CONFIGURATOR = "LENDING_POOL_CONFIGURATOR";
    event LendingPoolConfiguratorUpdated(address indexed newAddress);

    constructor(address owner) Ownable(owner) {}

    function setLendingPoolConfigurator(address configurator) external onlyOwner {
        _setAddress(LENDING_POOL_CONFIGURATOR, configurator);
        emit LendingPoolConfiguratorUpdated(configurator);
    }

    function getLendingPoolConfigurator() external view returns (address) {
        return getAddress(LENDING_POOL_CONFIGURATOR);
    }
    // same pattern (constant key + setter + event + getter) for:
    // LENDING_POOL_CORE, LENDING_POOL, DATA_PROVIDER, PRICE_ORACLE, …
}
```

While recording, the instructor first forgot to actually write `addresses[key] = value` and the `return` in the getter. The compiler didn't complain at first, so check these.

The core takes the provider in its constructor:

```solidity
LendingPoolAddressesProvider private immutable i_addressesProvider;

constructor(address addressesProvider) {
    if (addressesProvider == address(0)) revert LendingPoolCore__ZeroAddress();
    i_addressesProvider = LendingPoolAddressesProvider(addressesProvider);
}

modifier onlyLendingPoolConfigurator() {
    if (msg.sender != i_addressesProvider.getLendingPoolConfigurator()) {
        revert LendingPoolCore__OnlyLendingPoolConfigurator();
    }
    _;
}
```

## `initReserve` on the core ([≈03:07:40](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=11260s))

```solidity
function initReserve(
    address reserve,
    address aTokenAddress,
    uint256 decimals,
    address interestRateStrategyAddress
) external onlyLendingPoolConfigurator {
    s_reserves[reserve].init(aTokenAddress, decimals, interestRateStrategyAddress);
    _addReserveToList(reserve);
    emit ReserveInitialized(reserve, aTokenAddress, interestRateStrategyAddress);
}
```

## Recap

- The core stores **reserve state** and **user-per-reserve state**, and holds the funds.
- Indexes start at 1 ray. Deposits grow with **linear** interest, borrows with **compound** interest.
- The addresses provider is the registry that every contract uses to find the others.
