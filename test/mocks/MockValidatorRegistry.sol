// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IValidatorRegistry, MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { VaultMath } from "src/libraries/VaultMath.sol";
import { NetuidOutOfRange, ValidatorSetMalformed } from "src/VaultErrors.sol";
import { MockStaking } from "./MockStaking.sol";

contract MockValidatorRegistry is IValidatorRegistry {
    struct Slot {
        bytes32[] hotkeys;
        uint16[] weights;
        bytes32[] owners;
    }

    mapping(uint256 => Slot) private _slots;
    mapping(uint256 => uint256) public override nonces;

    error OwnerlessHotkey(bytes32 hotkey);

    function setValidators(uint256 netuid, bytes32[] memory hotkeys, uint16[] memory weights) external {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        uint256 count = hotkeys.length;
        if (count == 0 || count > MAX_VALIDATORS || count != weights.length) revert ValidatorSetMalformed();
        bytes32[] memory owners = new bytes32[](count);
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            if (hotkeys[i] == bytes32(0) || weights[i] == 0) revert ValidatorSetMalformed();
            for (uint256 j; j < i; ++j) {
                if (hotkeys[j] == hotkeys[i]) revert ValidatorSetMalformed();
            }
            (bool exists, bytes32 owner) = IStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkeys[i]);
            if (!exists) revert OwnerlessHotkey(hotkeys[i]);
            owners[i] = owner;
            sum += weights[i];
        }
        if (sum != VaultMath.BPS_BASE) revert ValidatorSetMalformed();
        _slots[netuid] = Slot(hotkeys, weights, owners);
        ++nonces[netuid];
    }

    /// @dev Allows malformed sets that the real registry rejects; owners are whoever holds the names now.
    function setRaw(uint256 netuid, bytes32[] memory hotkeys, uint16[] memory weights) external {
        Slot storage slot = _slots[netuid];
        slot.hotkeys = hotkeys;
        slot.weights = weights;
        delete slot.owners;
        for (uint256 i; i < hotkeys.length; ++i) {
            slot.owners.push(MockStaking(STAKING_PRECOMPILE).ownerOf(hotkeys[i]));
        }
        nonces[netuid] += 1;
    }

    function getValidators(uint256 netuid)
        external
        view
        override
        returns (bytes32[] memory hotkeys, uint16[] memory weights, bytes32[] memory owners)
    {
        Slot storage slot = _slots[netuid];
        return (slot.hotkeys, slot.weights, slot.owners);
    }
}
