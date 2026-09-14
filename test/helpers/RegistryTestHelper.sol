// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { VaultMath } from "src/libraries/VaultMath.sol";
import { MockStaking } from "../mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

abstract contract RegistryTestHelper is Test {
    function _etchStakingMock() internal {
        vm.etch(STAKING_PRECOMPILE, address(new MockStaking()).code);
    }

    function _recordHotkeyOwner(bytes32 hotkey) internal {
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwned(hotkey, true);
    }

    function _recordHotkeyOwners(bytes32[] memory hotkeys) internal {
        for (uint256 i; i < hotkeys.length; ++i) {
            _recordHotkeyOwner(hotkeys[i]);
        }
    }

    function _hotkeysFrom(string memory salt, uint256 count) internal pure returns (bytes32[] memory hotkeys) {
        hotkeys = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            hotkeys[i] = keccak256(abi.encodePacked(salt, i));
        }
    }

    function _evenWeights(uint256 count) internal pure returns (uint16[] memory weights) {
        weights = new uint16[](count);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 slots = uint16(count);
        uint16 share = VaultMath.BPS_BASE / slots;
        for (uint16 i; i + 1 < slots; ++i) {
            weights[i] = share;
        }
        weights[slots - 1] = VaultMath.BPS_BASE - share * (slots - 1);
    }
}
