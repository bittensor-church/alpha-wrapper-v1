// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { INeuron, NEURON_PRECOMPILE } from "./interfaces/INeuron.sol";

/// @dev Makes a subnet clone's account a hotkey, which refuses coldkey swaps into it, without the clone owning
///      it: the chain hands a subnet to the coldkey owning its most convicted hotkey and locks the owner's cut
///      onto that coldkey.
contract CloneOwner {
    constructor(bytes32 hotkey) { INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(hotkey); }
}
