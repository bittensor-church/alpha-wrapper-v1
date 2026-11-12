// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { NetuidOutOfRange, ZeroHotkey } from "src/VaultErrors.sol";
import { RegistryTestHelper } from "./helpers/RegistryTestHelper.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { PlaceholderValidatorRegistry } from "src/PlaceholderValidatorRegistry.sol";
import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract PlaceholderValidatorRegistryTest is RegistryTestHelper {
    PlaceholderValidatorRegistry internal registry;
    address internal registryOwner = makeAddr("registryOwner");
    bytes32 internal constant HOTKEY = keccak256("hotkey");
    bytes32 internal constant HOTKEY_COLDKEY = keccak256("owner");
    uint256 internal constant NETUID = 1;

    function setUp() public {
        registry = new PlaceholderValidatorRegistry(registryOwner);
        _etchStakingMock();
        _ownedBy(HOTKEY, HOTKEY_COLDKEY);
    }

    function _ownedBy(bytes32 hotkey, bytes32 owner) internal {
        MockStaking(STAKING_PRECOMPILE).setHotkeyOwner(hotkey, owner);
    }

    function _mockOwnerRecord(bytes32 hotkey, bool exists, bytes32 owner) internal {
        vm.mockCall(STAKING_PRECOMPILE, abi.encodeCall(IStaking.getHotkeyOwner, (hotkey)), abi.encode(exists, owner));
    }

    function _setValidatorAsOwner(uint256 netuid, bytes32 hotkey) internal {
        vm.prank(registryOwner);
        registry.setValidator(netuid, hotkey);
    }

    function _assertValidator(uint256 netuid, bytes32 hotkey, uint256 nonce) internal view {
        IValidatorRegistry asInterface = IValidatorRegistry(address(registry));
        (bytes32[] memory hotkeys, uint16[] memory weights) = asInterface.getValidators(netuid);
        assertEq(hotkeys.length, 1);
        assertEq(weights.length, 1);
        assertEq(hotkeys[0], hotkey);
        assertEq(weights[0], 10_000);
        assertEq(asInterface.nonces(netuid), nonce);
    }

    function _assertUnconfigured(uint256 netuid) internal view {
        (bytes32[] memory hotkeys, uint16[] memory weights) = registry.getValidators(netuid);
        assertEq(hotkeys.length, 0);
        assertEq(weights.length, 0);
        assertEq(registry.nonces(netuid), 0);
    }

    function test_SetValidator_UsesOwnerExistenceFlag() public {
        // Subtensor returns the stored AccountId independently of the existence flag.
        _mockOwnerRecord(HOTKEY, true, 0);
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, 1);
    }

    function test_GetValidators_UnconfiguredSubnetIsEmpty() public view {
        _assertUnconfigured(NETUID);
        _assertUnconfigured(type(uint256).max);
    }

    function test_SetValidator_ImmediatelyRecordsHotkeyAndNonce() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit PlaceholderValidatorRegistry.ValidatorUpdated(NETUID, 1, HOTKEY);
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, 1);
    }

    function test_SetValidator_ReplacesHotkey() public {
        _setValidatorAsOwner(NETUID, HOTKEY);
        bytes32 nextHotkey = keccak256("next");
        _ownedBy(nextHotkey, keccak256("nextOwner"));
        vm.expectEmit(true, true, false, true, address(registry));
        emit PlaceholderValidatorRegistry.ValidatorUpdated(NETUID, 2, nextHotkey);
        _setValidatorAsOwner(NETUID, nextHotkey);
        _assertValidator(NETUID, nextHotkey, 2);
    }

    function test_SetValidator_SameHotkeyAdvancesTheNonce() public {
        _setValidatorAsOwner(NETUID, HOTKEY);
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, 2);
        _ownedBy(HOTKEY, keccak256("nextOwner"));
        _setValidatorAsOwner(NETUID, HOTKEY);
        _assertValidator(NETUID, HOTKEY, 3);
    }

    function test_GetValidators_KeepsAnAttestedHotkeyThatLostItsOwner() public {
        _setValidatorAsOwner(NETUID, HOTKEY);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(HOTKEY, true);
        _assertValidator(NETUID, HOTKEY, 1);
    }

    function test_SetValidator_SubnetsAreIndependent() public {
        _setValidatorAsOwner(NETUID, HOTKEY);
        _setValidatorAsOwner(2, HOTKEY);
        bytes32 nextHotkey = keccak256("next");
        _ownedBy(nextHotkey, HOTKEY_COLDKEY);
        _setValidatorAsOwner(NETUID, nextHotkey);
        _assertValidator(NETUID, nextHotkey, 2);
        _assertValidator(2, HOTKEY, 1);
        _assertUnconfigured(3);
    }

    function test_SetValidator_AcceptsNetuidBoundaries() public {
        _setValidatorAsOwner(0, HOTKEY);
        _setValidatorAsOwner(type(uint16).max, HOTKEY);
        _assertValidator(0, HOTKEY, 1);
        _assertValidator(type(uint16).max, HOTKEY, 1);
    }

    function test_RevertWhen_NetuidIsOutOfRange() public {
        vm.expectRevert(NetuidOutOfRange.selector);
        _setValidatorAsOwner(uint256(type(uint16).max) + 1, HOTKEY);
    }

    function test_RevertWhen_HotkeyIsZero() public {
        vm.expectRevert(ZeroHotkey.selector);
        _setValidatorAsOwner(NETUID, 0);
    }

    function test_RevertWhen_HotkeyHasNoOwner() public {
        _mockOwnerRecord(HOTKEY, false, HOTKEY_COLDKEY);
        vm.expectRevert(abi.encodeWithSelector(PlaceholderValidatorRegistry.OwnerlessHotkey.selector, HOTKEY));
        _setValidatorAsOwner(NETUID, HOTKEY);
    }

    function test_RevertWhen_OwnerRenounces() public {
        vm.prank(registryOwner);
        vm.expectRevert(PlaceholderValidatorRegistry.RenunciationDisabled.selector);
        registry.renounceOwnership();
    }

    function testFuzz_RevertWhen_CallerIsNotOwner(uint256 offset) public {
        address caller;
        // Any nonzero offset, wrapping around the address space, lands on an address other than the owner.
        unchecked {
            caller = address(uint160(registryOwner) + uint160(bound(offset, 1, type(uint160).max)));
        }
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        registry.setValidator(NETUID, HOTKEY);
    }

    function testFuzz_SetValidator_ValidSingleValidator(uint16 netuid, bytes32 hotkey, bytes32 owner) public {
        hotkey = bytes32(bound(uint256(hotkey), 1, type(uint256).max));
        _ownedBy(hotkey, owner);
        _setValidatorAsOwner(netuid, hotkey);
        _assertValidator(netuid, hotkey, 1);
    }

    function testFuzz_RevertWhen_NetuidIsOutOfRange(uint256 netuid) public {
        netuid = bound(netuid, uint256(type(uint16).max) + 1, type(uint256).max);
        vm.expectRevert(NetuidOutOfRange.selector);
        _setValidatorAsOwner(netuid, HOTKEY);
    }
}
