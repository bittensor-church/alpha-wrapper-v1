// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @dev Excerpt of the Neuron precompile interface published in Subtensor; docs/deployment.md lists the
///      behavior the vault relies on.
interface INeuron {
    function tryAssociateHotkey(bytes32 hotkey) external;
}

address constant NEURON_PRECOMPILE = 0x0000000000000000000000000000000000000804;
