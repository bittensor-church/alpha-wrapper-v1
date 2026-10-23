// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CloneBase } from "./CloneBase.sol";
import { IBalanceTransfer, BALANCE_TRANSFER_PRECOMPILE } from "./interfaces/IBalanceTransfer.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";

contract SubnetClone is CloneBase {
    function moveStake(bytes32 fromHotkey, bytes32 toHotkey, uint256 netuid, uint256 amount) external onlyWrapper {
        if (amount > 0) { IStaking(STAKING_PRECOMPILE).moveStake(fromHotkey, toHotkey, netuid, netuid, amount); }
    }

    function setRejectStakingHotkeyGrowth(bool enabled) external onlyWrapper {
        IStaking(STAKING_PRECOMPILE).setRejectStakingHotkeyGrowth(enabled);
    }

    function transferAllTao(bytes32 destination) external onlyWrapper {
        IBalanceTransfer(BALANCE_TRANSFER_PRECOMPILE).transferAll(destination, false);
    }
}
