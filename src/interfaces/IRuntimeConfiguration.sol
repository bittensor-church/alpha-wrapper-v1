// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

interface IRuntimeConfiguration {
    function getBalancesConstants() external view
        returns (uint256 existentialDeposit, uint32 maxLocks, uint32 maxReserves, uint32 maxFreezes);
}

address constant RUNTIME_CONFIGURATION_PRECOMPILE = 0x0000000000000000000000000000000000000812;
