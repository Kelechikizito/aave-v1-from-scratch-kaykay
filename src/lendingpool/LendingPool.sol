// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// The LendingPool is the collection of all the asset reserves(e.g. DAI, USDC, WETH, etc.)
// Total liquidity is the combined value of everything in the pool, measured in ETH.
// To borrow from the lending pool, you must lock up assets worth more than what you borrow.(over-collateralization)
// Yes. The borrower chooses. When you open a borrow, you pick either the stable or the variable rate for that position, as the whitepaper says: “Every borrow position can be opened with a stable or variable rate.”

// What happens behind the scenes on any action
// Lending Pool receives the request.
// Data Provider (with the Price Oracle) checks that it’s allowed and safe.
// Core moves the tokens and updates State Data.
// Interest Rate Strategy (with the Lending Rate Oracle) recalculates the rates.
// Tokenization mints or burns aTokens if it was a deposit or redeem.

/**
 * @title LendingPool
 * @author Kelechi Kizito Ugwu
 * @notice The lending pool is the collection of all the asset reserves(e.g. DAI, USDC, WETH, etc.)
 * @notice The lending pool uses the lending pool core and the lending pool data provider to manage the reserves and the state of the pool.
 * @dev
 */
contract LendingPool {}
