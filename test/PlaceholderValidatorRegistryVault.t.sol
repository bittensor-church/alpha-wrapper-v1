// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { PlaceholderValidatorRegistry } from "src/PlaceholderValidatorRegistry.sol";
import { ChosenHotkeyNotInSet } from "src/VaultErrors.sol";

contract PlaceholderValidatorRegistryVaultTest is AlphaVaultTestBase {
    PlaceholderValidatorRegistry private placeholderRegistry;

    function setUp() public override {
        super.setUp();
        placeholderRegistry = new PlaceholderValidatorRegistry(address(this));
        placeholderRegistry.setValidator(NETUID1, hotkey1);
        placeholderRegistry.setValidator(NETUID2, hotkey2);
        (vault, lens) = _deployVaultAndLens(address(placeholderRegistry));
    }

    function test_Wrap_AllocatesToSoleValidator() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        assertEq(_getVaultStake(hotkey1, NETUID1), 10 * ALPHA);
        assertEq(_getVaultStake(hotkey2, NETUID1), 0);
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
        assertEq(_lastSeen(TOKEN1), _hotkeys(hotkey1), "the record holds the sole validator");
    }

    function test_RevertWhen_WrapHotkeyIsUnlisted() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        vm.expectRevert(ChosenHotkeyNotInSet.selector);
        _wrapHotkey(alice, NETUID1, hotkey2);
    }

    function test_Rebalance_RotationPreservesSharesAndOtherSubnet() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _depositAndWrap(bob, NETUID2, 20 * ALPHA);
        placeholderRegistry.setValidator(NETUID1, hotkey3);
        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getVaultStake(hotkey3, NETUID1), 10 * ALPHA);
        assertEq(vault.balanceOf(alice, TOKEN1), 10e18, "10 alpha keeps its 1e9 shares per RAO");
        assertEq(_getVaultStake(hotkey2, NETUID2), 20 * ALPHA);
        assertEq(_lastSeen(TOKEN1), _hotkeys(hotkey3), "the record follows the rotation");
    }

    function test_Unwrap_ConsolidatesRotatedValidator() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        placeholderRegistry.setValidator(NETUID1, hotkey3);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 1);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(_getVaultStake(hotkey1, NETUID1), 0);
        assertEq(_getStakeForColdkey(hotkey3, _toSubstrate(alice), NETUID1), 10 * ALPHA);
    }

    function test_UnwrapForTao_DrainsRotatedValidator() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        placeholderRegistry.setValidator(NETUID1, hotkey3);
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(lens.totalStake(TOKEN1), 0);
        assertEq(alice.balance - balanceBefore, 0.5e18, "10 alpha sold at 0.05 TAO");
    }

    function _parkAfterASweptSlot() private {
        _parkedPosition(10 * ALPHA);
        assertTrue(vault.awaitingAttestation(TOKEN1));
        assertEq(_parkedStake(NETUID1), 10 * ALPHA);
    }

    function test_Rebalance_SameHotkeyResubmissionReleasesParking() public {
        _parkAfterASweptSlot();

        placeholderRegistry.setValidator(NETUID1, hotkey1);
        assertFalse(vault.awaitingAttestation(TOKEN1), "the fresh nonce is the owner's decision");
        vault.rebalance(NETUID1);

        assertEq(_parkedStake(NETUID1), 0);
        assertEq(_getVaultStake(hotkey1, NETUID1), 10 * ALPHA);
        assertTrue(lens.isBackingIntact(TOKEN1));
    }

    function test_Rebalance_NewOwnerReleasesRecoveredParking() public {
        _parkAfterASweptSlot();

        placeholderRegistry.transferOwnership(bob);
        assertTrue(vault.awaitingAttestation(TOKEN1), "nomination does not publish a validator update");
        vm.prank(bob);
        placeholderRegistry.acceptOwnership();
        assertTrue(vault.awaitingAttestation(TOKEN1), "acceptance does not publish a validator update");
        assertEq(placeholderRegistry.nonces(NETUID1), 1);
        _recordHotkeyOwner(hotkey4);
        vm.prank(bob);
        placeholderRegistry.setValidator(NETUID1, hotkey4);
        assertFalse(vault.awaitingAttestation(TOKEN1));
        vault.rebalance(NETUID1);
        assertEq(_parkedStake(NETUID1), 0);
        assertEq(_getVaultStake(hotkey4, NETUID1), 10 * ALPHA);
        assertEq(vault.balanceOf(alice, TOKEN1), 10e18, "parking and release leave the 1e19 shares untouched");
        assertTrue(lens.isBackingIntact(TOKEN1));
    }
}
