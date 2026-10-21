// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { INeuron, NEURON_PRECOMPILE } from "./interfaces/INeuron.sol";

/// @dev Owns one subnet clone's account as a hotkey and never acts again. Owning a hotkey costs the owner a
///      staking-list entry for good, and a throwaway owner keeps that entry off the vault's own list.
contract CloneOwner {
    constructor(bytes32 hotkey) { INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(hotkey); }
}
