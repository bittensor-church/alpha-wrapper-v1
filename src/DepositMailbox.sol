// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CloneBase } from "./CloneBase.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";

contract DepositMailbox is CloneBase {
    /// @notice Transfer staked alpha to another coldkey, landing it on a different hotkey of the same subnet.
    function transferStakeAndHotkey(bytes32 destinationColdkey, bytes32 fromHotkey, bytes32 toHotkey, uint16 netuid,
        uint64 amount) external onlyWrapper {
        if (amount > 0) {
            IStaking(STAKING_PRECOMPILE)
                .transferStakeAndHotkey(destinationColdkey, fromHotkey, toHotkey, netuid, netuid, amount);
        }
    }
}
