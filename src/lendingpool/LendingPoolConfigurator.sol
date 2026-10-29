// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// The Lending Pool Configurator is the only way to add reserves or change risk settings. 
// It writes into the Lending Pool and Core. As we covered earlier, this is the governance-controlled part.

/**
 * @title LendingPoolConfigurator
 * @author Kelechi Kizito Ugwu
 * @notice The lending pool configurator has configuration functions for the lending pool and the lending pool core, such as:
    * @notice reserve intitialization, configuration, reserve enabling/disabling on borrowing, reverve enabling/disabling on collateral usage. Also, integrated with the governace protocol.
 * @dev 
 */
contract LendingPoolConfigurator {}