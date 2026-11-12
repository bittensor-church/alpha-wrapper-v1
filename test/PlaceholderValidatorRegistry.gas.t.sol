// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { PlaceholderValidatorRegistry } from "src/PlaceholderValidatorRegistry.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

/// forge-config: default.isolate = true
contract PlaceholderValidatorRegistryGasTest is Test {
    PlaceholderValidatorRegistry private registry;
    bytes32 private constant HOTKEY = keccak256("hotkey");
    bytes32 private constant NEXT_HOTKEY = keccak256("next hotkey");

    function setUp() public {
        vm.etch(STAKING_PRECOMPILE, address(new MockStaking()).code);
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwned(HOTKEY, true);
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwned(NEXT_HOTKEY, true);
        registry = new PlaceholderValidatorRegistry(address(this));
    }

    function test_gas_setValidator_firstCommit() public {
        registry.setValidator(1, HOTKEY);
        vm.snapshotGasLastCall("PlaceholderValidatorRegistry", "setValidator: first commit");

        _assertSoleValidator(HOTKEY, 1);
    }

    function test_gas_setValidator_rotation() public {
        registry.setValidator(1, HOTKEY);
        registry.setValidator(1, NEXT_HOTKEY);
        vm.snapshotGasLastCall("PlaceholderValidatorRegistry", "setValidator: rotation");

        _assertSoleValidator(NEXT_HOTKEY, 2);
    }

    function test_gas_setValidator_refresh() public {
        registry.setValidator(1, HOTKEY);
        registry.setValidator(1, HOTKEY);
        vm.snapshotGasLastCall("PlaceholderValidatorRegistry", "setValidator: refresh");

        _assertSoleValidator(HOTKEY, 2);
    }

    function test_gas_getValidators() public {
        registry.setValidator(1, HOTKEY);
        registry.getValidators(1);
        vm.snapshotGasLastCall("PlaceholderValidatorRegistry", "getValidators");

        _assertSoleValidator(HOTKEY, 1);
    }

    function test_gas_getValidators_unconfigured() public {
        registry.getValidators(1);
        vm.snapshotGasLastCall("PlaceholderValidatorRegistry", "getValidators: unconfigured");

        (bytes32[] memory hotkeys, uint16[] memory weights) = registry.getValidators(1);
        assertEq(hotkeys.length, 0);
        assertEq(weights.length, 0);
    }

    function _assertSoleValidator(bytes32 hotkey, uint256 nonce) private view {
        (bytes32[] memory hotkeys, uint16[] memory weights) = registry.getValidators(1);
        assertEq(hotkeys.length, 1);
        assertEq(hotkeys[0], hotkey);
        assertEq(weights[0], 10_000);
        assertEq(registry.nonces(1), nonce);
    }
}
