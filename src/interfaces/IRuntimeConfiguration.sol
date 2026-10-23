// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

address constant RUNTIME_CONFIGURATION_PRECOMPILE = 0x0000000000000000000000000000000000000812;

interface IRuntimeConfiguration {
    function getSubtensorEconomicConstants() external view returns (
        uint256 initialIssuance,
        uint256 initialRaoRecycledForRegistration,
        uint256 initialBurn,
        uint256 initialMinBurn,
        uint256 initialMaxBurn,
        uint256 initialMinStake,
        uint256 initialMinTransfer,
        uint256 minBurnUpperBound,
        uint256 maxBurnLowerBound,
        uint256 initialNetworkMinLockCost,
        uint256 keySwapCost,
        uint256 keySwapOnSubnetCost,
        uint256 minBalanceToPerformColdkeySwap
    );
}
