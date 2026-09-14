// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { RegistryTestHelper } from "./helpers/RegistryTestHelper.sol";
import { MockValidatorRegistry } from "./mocks/MockValidatorRegistry.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { NetuidOutOfRange, ValidatorSetMalformed } from "src/VaultErrors.sol";

contract MockValidatorRegistryTest is RegistryTestHelper {
    MockValidatorRegistry private registry;
    uint256 private constant NETUID = 7;

    function setUp() public {
        _etchStakingMock();
        registry = new MockValidatorRegistry();
    }

    function test_UnconfiguredSubnet_ReturnsEmptyArraysAndZeroNonce() public view {
        (bytes32[] memory hotkeys, uint16[] memory weights, bytes32[] memory owners) = registry.getValidators(NETUID);
        assertEq(hotkeys.length, 0);
        assertEq(weights.length, 0);
        assertEq(owners.length, 0);
        assertEq(registry.nonces(NETUID), 0);
    }

    function testFuzz_Update_ReplacesAnyValidSetSize(uint256 firstCount, uint256 secondCount) public {
        firstCount = bound(firstCount, 1, MAX_VALIDATORS);
        secondCount = bound(secondCount, 1, MAX_VALIDATORS);
        bytes32[] memory first = _hotkeysFrom("first", firstCount);
        bytes32[] memory second = _hotkeysFrom("second", secondCount);
        _recordHotkeyOwners(first);
        _recordHotkeyOwners(second);
        registry.setValidators(NETUID, first, _evenWeights(firstCount));
        registry.setValidators(NETUID, second, _evenWeights(secondCount));

        (bytes32[] memory hotkeys, uint16[] memory weights, bytes32[] memory owners) = registry.getValidators(NETUID);
        assertEq(hotkeys, second);
        assertEq(weights.length, secondCount);
        assertEq(owners.length, secondCount);
        uint16[] memory expectedWeights = _evenWeights(secondCount);
        for (uint256 i; i < secondCount; ++i) {
            assertEq(weights[i], expectedWeights[i]);
            assertEq(owners[i], MockStaking(STAKING_PRECOMPILE).ownerOf(second[i]));
        }
        assertEq(registry.nonces(NETUID), 2);
    }

    function test_OwnerSnapshot_ChangesOnlyOnExplicitRefresh() public {
        bytes32[] memory hotkeys = _hotkeysFrom("validator", 1);
        _recordHotkeyOwners(hotkeys);
        registry.setValidators(NETUID, hotkeys, _evenWeights(1));
        (,, bytes32[] memory originalOwners) = registry.getValidators(NETUID);
        bytes32 newOwner = keccak256("new-owner");
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwner(hotkeys[0], newOwner);
        (,, bytes32[] memory unchangedOwners) = registry.getValidators(NETUID);
        assertEq(unchangedOwners, originalOwners);
        assertEq(registry.nonces(NETUID), 1);

        registry.setValidators(NETUID, hotkeys, _evenWeights(1));
        (,, bytes32[] memory refreshedOwners) = registry.getValidators(NETUID);
        assertEq(refreshedOwners[0], newOwner);
        assertEq(registry.nonces(NETUID), 2);
    }

    function test_DeletedOwner_RemainsSnapshottedAndCannotBeRefreshed() public {
        bytes32[] memory hotkeys = _hotkeysFrom("validator", 1);
        _recordHotkeyOwners(hotkeys);
        registry.setValidators(NETUID, hotkeys, _evenWeights(1));
        (,, bytes32[] memory originalOwners) = registry.getValidators(NETUID);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkeys[0], true);
        _recordHotkeyOwners(hotkeys);

        vm.expectRevert(abi.encodeWithSelector(MockValidatorRegistry.OwnerlessHotkey.selector, hotkeys[0]));
        registry.setValidators(NETUID, hotkeys, _evenWeights(1));
        (,, bytes32[] memory owners) = registry.getValidators(NETUID);
        assertEq(owners, originalOwners);
        assertEq(registry.nonces(NETUID), 1);
    }

    function test_UnknownOwner_RejectsTheWholeUpdate() public {
        bytes32[] memory original = _hotkeysFrom("original", 1);
        _recordHotkeyOwners(original);
        registry.setValidators(NETUID, original, _evenWeights(1));
        bytes32[] memory replacement = _hotkeysFrom("replacement", 2);
        _recordHotkeyOwner(replacement[0]);

        vm.expectRevert(abi.encodeWithSelector(MockValidatorRegistry.OwnerlessHotkey.selector, replacement[1]));
        registry.setValidators(NETUID, replacement, _evenWeights(2));
        (bytes32[] memory hotkeys,,) = registry.getValidators(NETUID);
        assertEq(hotkeys, original);
        assertEq(registry.nonces(NETUID), 1);
    }

    function test_EmptySet_LeavesThePreviousSetIntact() public {
        _assertMalformedUpdateLeavesPreviousSet(new bytes32[](0), new uint16[](0));
    }

    function test_TooManyValidators_LeavesThePreviousSetIntact() public {
        _assertMalformedUpdateLeavesPreviousSet(
            _hotkeysFrom("replacement", MAX_VALIDATORS + 1), _evenWeights(MAX_VALIDATORS + 1)
        );
    }

    function test_MismatchedLengths_LeavesThePreviousSetIntact() public {
        _assertMalformedUpdateLeavesPreviousSet(_hotkeysFrom("replacement", 2), _evenWeights(1));
    }

    function test_ZeroHotkey_LeavesThePreviousSetIntact() public {
        bytes32[] memory hotkeys = _hotkeysFrom("replacement", 2);
        hotkeys[0] = bytes32(0);
        _assertMalformedUpdateLeavesPreviousSet(hotkeys, _evenWeights(2));
    }

    function test_DuplicateHotkeys_LeavesThePreviousSetIntact() public {
        bytes32[] memory hotkeys = _hotkeysFrom("replacement", 2);
        hotkeys[1] = hotkeys[0];
        _assertMalformedUpdateLeavesPreviousSet(hotkeys, _evenWeights(2));
    }

    function test_ZeroWeightWithValidSum_LeavesThePreviousSetIntact() public {
        uint16[] memory weights = new uint16[](2);
        weights[1] = 10_000;
        _assertMalformedUpdateLeavesPreviousSet(_hotkeysFrom("replacement", 2), weights);
    }

    function _assertMalformedUpdateLeavesPreviousSet(bytes32[] memory hotkeys, uint16[] memory weights) private {
        bytes32[] memory original = _hotkeysFrom("original", 1);
        _recordHotkeyOwners(original);
        registry.setValidators(NETUID, original, _evenWeights(1));
        (,, bytes32[] memory originalOwners) = registry.getValidators(NETUID);
        _recordHotkeyOwners(hotkeys);

        vm.expectRevert(ValidatorSetMalformed.selector);
        registry.setValidators(NETUID, hotkeys, weights);
        (bytes32[] memory retained, uint16[] memory retainedWeights, bytes32[] memory retainedOwners) =
            registry.getValidators(NETUID);
        assertEq(retained, original);
        assertEq(retainedWeights.length, 1);
        assertEq(retainedWeights[0], 10_000);
        assertEq(retainedOwners, originalOwners);
        assertEq(registry.nonces(NETUID), 1);
    }

    function test_WeightsMustSumToOneHundredPercent() public {
        bytes32[] memory hotkeys = _hotkeysFrom("validator", 1);
        _recordHotkeyOwners(hotkeys);
        uint16[] memory weights = _evenWeights(1);
        weights[0] -= 1;
        vm.expectRevert(ValidatorSetMalformed.selector);
        registry.setValidators(NETUID, hotkeys, weights);
        assertEq(registry.nonces(NETUID), 0);
    }

    function test_SubnetNonces_AdvanceIndependentlyIncludingRefreshes() public {
        bytes32[] memory hotkeys = _hotkeysFrom("validator", 1);
        _recordHotkeyOwners(hotkeys);
        registry.setValidators(NETUID, hotkeys, _evenWeights(1));
        registry.setValidators(NETUID + 1, hotkeys, _evenWeights(1));
        registry.setValidators(NETUID, hotkeys, _evenWeights(1));
        assertEq(registry.nonces(NETUID), 2);
        assertEq(registry.nonces(NETUID + 1), 1);
    }

    function test_OutOfRangeSubnet_IsRejected() public {
        bytes32[] memory hotkeys = _hotkeysFrom("validator", 1);
        _recordHotkeyOwners(hotkeys);
        vm.expectRevert(NetuidOutOfRange.selector);
        registry.setValidators(uint256(type(uint16).max) + 1, hotkeys, _evenWeights(1));
    }

    function test_RawResponse_PreservesMalformedDataForVaultDefensiveTests() public {
        bytes32[] memory hotkeys = new bytes32[](1);
        uint16[] memory weights = new uint16[](2);
        registry.setRaw(NETUID, hotkeys, weights);
        (bytes32[] memory storedHotkeys, uint16[] memory storedWeights,) = registry.getValidators(NETUID);
        assertEq(storedHotkeys, hotkeys);
        assertEq(storedWeights.length, 2);
        assertEq(registry.nonces(NETUID), 1);
    }
}
