// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { INeuron, NEURON_PRECOMPILE } from "./interfaces/INeuron.sol";

/// @dev Owns one subnet clone's account as a hotkey and never acts again. A hotkey stays on its owner's
///      capped staking list for good, so the vault's own list would fill one clone at a time.
contract CloneOwner {
    constructor(bytes32 hotkey) { INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(hotkey); }
}
