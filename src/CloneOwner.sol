// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { INeuron, NEURON_PRECOMPILE } from "./interfaces/INeuron.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";

/// @dev Makes a subnet clone's account a hotkey, which refuses coldkey swaps into it, and holds every
///      other hotkey claim the clone's stake needs, so the clone's own coldkey owns nothing.
contract CloneOwner {
    address public immutable vault;

    error NotVault();

    constructor(bytes32 hotkey, address _vault) {
        vault = _vault;
        INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(hotkey);
        IStaking(STAKING_PRECOMPILE).setRejectStakingHotkeyGrowth(true);
    }

    function tryAssociateHotkey(bytes32 hotkey) external {
        if (msg.sender != vault) revert NotVault();
        INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(hotkey);
    }
}
