// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract AToken is ERC20 {
    using SafeERC20 for ERC20;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
}
