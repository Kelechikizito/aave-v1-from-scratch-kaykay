// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// The LendingPool is the collection of all the asset reserves(e.g. DAI, USDC, WETH, etc.)
// Total liquidity is the combined value of everything in the pool, measured in ETH.
// To borrow from the lending pool, you must lock up assets worth more than what you borrow.(over-collateralization)
// Yes. The borrower chooses. When you open a borrow, you pick either the stable or the variable rate for that position, as the whitepaper says: “Every borrow position can be opened with a stable or variable rate.”

contract LendingPool {}
