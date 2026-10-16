// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IValidatorRegistry, MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";
import { StakeOps } from "src/libraries/StakeOps.sol";
import { VaultMath } from "src/libraries/VaultMath.sol";
import { NetuidOutOfRange, ValidatorSetMalformed } from "src/VaultErrors.sol";

contract MockValidatorRegistry is IValidatorRegistry {
    struct Slot {
        bytes32[] hotkeys;
        uint16[] weights;
    }

    mapping(uint256 => Slot) private _slots;
    mapping(uint256 => uint256) public override nonces;

    error OwnerlessHotkey(bytes32 hotkey);

    function setValidators(uint256 netuid, bytes32[] memory hotkeys, uint16[] memory weights) external {
        if (netuid > type(uint16).max) revert NetuidOutOfRange();
        uint256 count = hotkeys.length;
        if (count == 0 || count > MAX_VALIDATORS || count != weights.length) revert ValidatorSetMalformed();
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            if (hotkeys[i] == bytes32(0) || weights[i] == 0) revert ValidatorSetMalformed();
            for (uint256 j; j < i; ++j) {
                if (hotkeys[j] == hotkeys[i]) revert ValidatorSetMalformed();
            }
            if (!StakeOps.hasOwner(hotkeys[i])) revert OwnerlessHotkey(hotkeys[i]);
            sum += weights[i];
        }
        if (sum != VaultMath.BPS_BASE) revert ValidatorSetMalformed();
        _slots[netuid] = Slot(hotkeys, weights);
        ++nonces[netuid];
    }

    /// @dev Allows malformed sets that the real registry rejects.
    function setRaw(uint256 netuid, bytes32[] memory hotkeys, uint16[] memory weights) external {
        _slots[netuid] = Slot(hotkeys, weights);
        nonces[netuid] += 1;
    }

    function getValidators(uint256 netuid)
        external
        view
        override
        returns (bytes32[] memory hotkeys, uint16[] memory weights)
    {
        Slot storage slot = _slots[netuid];
        return (slot.hotkeys, slot.weights);
    }
}
