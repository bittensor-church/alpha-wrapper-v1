// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CloneBase } from "./CloneBase.sol";
import { IAddressMapping, ADDRESS_MAPPING_PRECOMPILE } from "./interfaces/IAddressMapping.sol";
import { INeuron, NEURON_PRECOMPILE } from "./interfaces/INeuron.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";

contract DepositMailbox is CloneBase {
    /// @dev Owning its own account as a hotkey keeps the mailbox unswappable even while it holds no stake,
    ///      because the chain refuses coldkey swaps into any hotkey, and lets deposits land on it whatever
    ///      its staking list holds.
    function _claimOwnHotkey() internal override {
        INeuron(NEURON_PRECOMPILE)
            .tryAssociateHotkey(IAddressMapping(ADDRESS_MAPPING_PRECOMPILE).addressMapping(address(this)));
    }

    /// @notice Transfer staked alpha to another coldkey, landing it on a different hotkey of the same subnet.
    function transferStakeAndHotkey(bytes32 destinationColdkey, bytes32 fromHotkey, bytes32 toHotkey, uint16 netuid,
        uint64 amount) external onlyWrapper {
        if (amount > 0) {
            IStaking(STAKING_PRECOMPILE)
                .transferStakeAndHotkey(destinationColdkey, fromHotkey, toHotkey, netuid, netuid, amount);
        }
    }
}
