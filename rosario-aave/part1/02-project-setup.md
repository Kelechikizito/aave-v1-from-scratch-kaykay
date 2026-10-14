# 2. Project setup

▶ [Watch from 00:08:42](https://www.youtube.com/watch?v=k8TRY5lcs8Q&t=522s) · Previous: [01](01-intro.md) · Next: [03 WadRayMath](03-wad-ray-math.md)

## Steps

```bash
forge init aave-v1-tutorial
cd aave-v1-tutorial
# delete the Counter example files (src/, test/, script/)
forge install OpenZeppelin/openzeppelin-contracts
```

Add remappings to `foundry.toml` so imports stay short:

```toml
remappings = [
  "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
]
```

Now you can write `import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";` instead of the full `lib/...` path.

Later in the video the instructor also adds a lint exclusion in `foundry.toml` to hide some `forge lint` warnings. This is optional.

## Conventions used throughout

- `pragma solidity 0.8.30;` and `// SPDX-License-Identifier: MIT`
- Each contract is laid out in the usual order, with a comment banner per section: errors → libraries (`using … for …`) → type declarations → state variables → events → modifiers → constructor → external → public → internal → private → view/pure.
- Custom errors are named `ContractName__ErrorName`, e.g. `LendingPoolCore__OnlyLendingPool`.
- Storage variables start with `s_` and immutables with `i_`.
- Internal library functions are tested through a **harness** contract that exposes them as `external`.
- The tutorial repo has a `docs/` folder with a page per contract.
