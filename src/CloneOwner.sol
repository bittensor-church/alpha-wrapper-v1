// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { INeuron, NEURON_PRECOMPILE } from "./interfaces/INeuron.sol";

/// @dev Makes a subnet clone's account a hotkey, which refuses coldkey swaps into it.
contract CloneOwner {
    constructor(bytes32 hotkey) { INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(hotkey); }
}
