// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";
import { BackingScenarios } from "./helpers/BackingScenarios.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { AttestedHotkeyRetired } from "src/VaultErrors.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract BackingRecordTest is BackingScenarios {
    function test_Wrap_RecordsWhereEachValidatorsAlphaIs() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 3, "one slot per attested validator");
        assertEq(slots[0].attested, hotkey1, "the slot is attested under the first validator");
        assertEq(slots[0].stakedUnder, hotkey1, "with nothing swapped the two agree");
        assertEq(slots[0].tracked, FIRST_SLOT, "the expectation is the slot's 3334 bps of 30 alpha");
        assertEq(slots[1].attested, hotkey2, "the second slot is attested under the second validator");
        assertEq(slots[1].stakedUnder, hotkey2, "and is staked under it");
        assertEq(slots[1].tracked, OTHER_SLOT, "expecting its 3333 bps of 30 alpha");
        assertEq(slots[2].attested, hotkey3, "the third slot is attested under the third validator");
        assertEq(slots[2].stakedUnder, hotkey3, "and is staked under it");
        assertEq(slots[2].tracked, OTHER_SLOT, "expecting the remaining 9.999 alpha");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and no clock is running");
    }

    function test_IntactSlot_NeverReadsASuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey5);

        vm.expectCall(STAKING_PRECOMPILE, abi.encodeCall(IStaking.getHotkeySuccessor, (hotkey1, uint16(NETUID1))), 0);
        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the slot answered from its own balance");
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey1, "and nothing moved the record");
    }

    function test_FollowedSwap_RecordsTheSuccessorAndKeepsTheAttestedHotkey() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the quote resolves the swap before any write");
        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].attested, hotkey1, "the registry still attests the original validator");
        assertEq(slots[0].stakedUnder, hotkey4, "the alpha is tracked at the successor");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "backing whole across the swap");
    }

    function test_RepeatedSwaps_AdvanceOneHopPerCall() public {
        uint256 netuid = 5;
        _registerSubnet(netuid, hotkey1);
        _depositAndWrap(alice, netuid, 10 * ALPHA);
        uint256 tokenId = vault.currentTokenId(netuid);

        _simulateFollowedSwap(netuid, hotkey1, hotkey4);
        vault.rebalance(netuid);

        _simulateFollowedSwap(netuid, hotkey4, hotkey5);

        assertTrue(lens.isBackingIntact(tokenId), "the quote reads the position as sound");
        vault.rebalance(netuid);

        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        assertEq(slots[0].attested, hotkey1, "the registry has not moved");
        assertEq(slots[0].stakedUnder, hotkey5, "the alpha is tracked at the latest successor");
        assertEq(lens.lastSeenHotkeys(tokenId)[0], hotkey5, "the lens reports the same hotkey");
        assertEq(lens.totalStake(tokenId), 10 * ALPHA, "backing whole across both swaps");
    }

    function test_FollowedSwap_EveryRailKeepsWorking() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        _assertEveryRailWorks(hotkey2, 47_500_000_000);

        assertEq(
            _getStakeForColdkey(hotkey4, _toSubstrate(bob), NETUID1), 15 * ALPHA, "the alpha exit paid at the successor"
        );
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing staked toward the swapped hotkey");
    }

    function test_Wrap_ChoosingASwappedAttestedHotkey_StakesAtItsSuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);

        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing lands on the swapped hotkey");
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the slot answers under the successor");
        assertEq(lens.totalStake(TOKEN1), 40 * ALPHA, "the deposit joined the backing");
    }

    function test_ReorderedSet_KeepsWeightsWithTheirValidators() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        // Per-subnet swapping retains the old owner, allowing the reordered attestation.
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey3, hotkey1, hotkey2), _weights(5000, 3000, 2000));
        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].attested, hotkey3, "slot order follows the attested set");
        assertEq(slots[1].attested, hotkey1, "the swapped validator kept its own weight slot");
        assertEq(slots[1].stakedUnder, hotkey4, "and its alpha is still tracked at the successor");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "nothing lost in the reorder");
    }

    function test_DroppedValidator_HasItsAlphaRolledOntoTheNewSet() public {
        _positionFollowingASwap(hotkey4);

        _setValidators(NETUID1, _hotkeys(hotkey2, hotkey3), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the successor was drained");
        assertEq(vault.recordedSlots(TOKEN1).length, 2, "the record matches the new set");
        assertEq(_getVaultStake(hotkey2, NETUID1), 15 * ALPHA, "half of 30 alpha on the first remaining validator");
        assertEq(_getVaultStake(hotkey3, NETUID1), 15 * ALPHA, "half of 30 alpha on the second");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "backing whole after the roll");
    }

    function test_SetAttestingTheSuccessor_CountsTheBalanceOnce() public {
        _positionFollowingASwap(hotkey4);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].attested, hotkey4, "the attested successor took over the slot");
        assertEq(slots[0].stakedUnder, hotkey4, "staked under itself");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and nothing is counted twice");
    }

    function _setAttestingASwappedHotkeyAndItsSuccessor() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        // Install the set before the swap removes ownership; ownerless entries cannot be newly attested.
        _setValidators(
            NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
    }

    function test_RevertWhen_RebalancingASetAttestingASwappedHotkeyAndItsSuccessor() public {
        _setAttestingASwappedHotkeyAndItsSuccessor();

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_UnwrappingUnderASetAttestingASwappedHotkeyAndItsSuccessor() public {
        uint256 shares = _setAttestingASwappedHotkeyAndItsSuccessor();

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);
    }

    function test_SetAttestingASwappedHotkeyAndItsSuccessor_KeepsTheTaoExitAndResumesOnceDropped() public {
        uint256 shares = _setAttestingASwappedHotkeyAndItsSuccessor();

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
        assertEq(alice.balance, 0.375e18, "the TAO exit sold 7.5 alpha at 0.05 TAO/alpha");

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "dropping the swapped hotkey resumes service");
        assertEq(lens.totalStake(TOKEN1), 22_500_000_000, "30 alpha less the 7.5 alpha sold");
    }

    function test_RebalanceAfterADrainedSwap_StakesTheShareAtTheSuccessor() public {
        _positionWithADrainedSwap(hotkey4);

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the slot answers under the successor");
        assertEq(_getVaultStake(hotkey4, NETUID1), REFILLED_FIRST_SLOT, "3334 bps of the remaining 19.998 alpha");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "and nothing was aimed at the swapped hotkey");
    }

    function test_UnwrapAfterADrainedSwap_StakesTheShareAtTheSuccessor() public {
        _positionWithADrainedSwap(hotkey4);

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the slot answers under the successor");
        // Alignment moves 4.99999995 alpha from hotkey3; the remaining 499,950 RAO move is below the floor.
        assertEq(_getVaultStake(hotkey4, NETUID1), 4_999_999_950, "which is where its share went");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 4_999_500_000, "the exit delivered a quarter");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for what is left");
    }

    function test_WrapAfterADrainedSwap_StakesTheShareAtTheSuccessor() public {
        _positionWithADrainedSwap(hotkey4);

        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        _wrapHotkey(bob, NETUID1, hotkey2);

        assertEq(vault.balanceOf(bob, TOKEN1), 6e18, "6 alpha against 19.998 alpha on 1.9998e19 shares");
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the slot answers under the successor");
        assertEq(_getVaultStake(hotkey4, NETUID1), 8_667_733_200, "3334 bps of 25.998 alpha");
    }

    function test_ValidatorSwappingBeforeItIsFunded_StakesItsShareAtTheSuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);

        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[2].attested, hotkey4, "the record keeps the attested validator");
        assertEq(slots[2].stakedUnder, hotkey5, "while its share sits at the successor");
        assertEq(_getVaultStake(hotkey5, NETUID1), OTHER_SLOT, "which is where the rebalance staked 9.999 alpha");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "backing whole across the swap");
    }

    function test_PerSubnetSwapAfterADrain_KeepsTheShareOnTheSuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _drainTheFirstSlot(alice, NETUID1);

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the slot keeps answering under the successor");
        assertEq(_getVaultStake(hotkey4, NETUID1), REFILLED_FIRST_SLOT, "3334 bps of the remaining 19.998 alpha");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing returns to the attested hotkey the validator left");
    }

    function _retiredAttestedHotkeyWithNoSuccessor() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
    }

    function test_RevertWhen_AnAlphaRailMeetsARetiredAttestedHotkeyWithNoSuccessor() public {
        uint256 shares = _retiredAttestedHotkeyWithNoSuccessor();

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vault.rebalance(NETUID1);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        _wrapHotkey(bob, NETUID1, hotkey2);
    }

    function test_RetiredAttestedHotkeyWithNoSuccessor_LeavesTheTaoExitOpen() public {
        uint256 shares = _retiredAttestedHotkeyWithNoSuccessor();

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);

        assertEq(alice.balance, 0.375e18, "7.5 alpha sold at 0.05 TAO/alpha");
        assertEq(vault.balanceOf(alice, TOKEN1), 2.25e19, "three quarters of the 3e19 shares remain");
    }

    function test_RevertWhen_RebalancingWithARetiredAttestedHotkeyAndARetiredSuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey5, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vault.rebalance(NETUID1);
    }

    function _positionWithTwoFollowedSwapsThenADrain() private {
        _positionFollowingASwap(hotkey4);
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey5, "the record followed both swaps");
        _drainTheFirstSlot(alice, NETUID1);
    }

    function test_RebalanceAfterTwoFollowedSwapsAndADrain_StakesTheShareAtTheRecordedHotkey() public {
        _positionWithTwoFollowedSwapsThenADrain();

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey5, "the slot stays on the hotkey it was found under");
        assertEq(_getVaultStake(hotkey5, NETUID1), REFILLED_FIRST_SLOT, "3334 bps of the remaining 19.998 alpha");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing was aimed at the retired successor");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for everything");
    }

    function test_UnwrapAfterTwoFollowedSwapsAndADrain_StakesTheShareAtTheRecordedHotkey() public {
        _positionWithTwoFollowedSwapsThenADrain();

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey5, "the slot stays on the hotkey it was found under");
        assertEq(_getVaultStake(hotkey5, NETUID1), 4_999_999_950, "which is where its share went");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 4_999_500_000, "the exit delivered a quarter");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for what is left");
    }

    function test_RebalanceAfterAReusedAttestedHotkey_StakesTheShareAtTheSuccessor() public {
        _reuseTheDrainedAttestedHotkeyAfterItsRecordedHotkeyRetires();

        vault.rebalance(NETUID1);

        _assertSlotMovedToTheSuccessor(REFILLED_FIRST_SLOT);
        assertEq(_realBacking(), OTHER_TWO_SLOTS, "moving the share created and lost nothing");
    }

    function test_UnwrapAfterAReusedAttestedHotkey_StakesTheShareAtTheSuccessor() public {
        _reuseTheDrainedAttestedHotkeyAfterItsRecordedHotkeyRetires();
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 4_999_500_000, "a quarter of 19.998 alpha");
        assertEq(_realBacking(), 14_998_500_000, "and the rest stays staked");
        _assertSlotMovedToTheSuccessor(4_999_999_950);
    }

    function test_WrapAfterAReusedAttestedHotkey_StakesTheShareAtTheSuccessor() public {
        _reuseTheDrainedAttestedHotkeyAfterItsRecordedHotkeyRetires();

        _depositSixAlphaAndWrapUnder(hotkey3);

        _assertSlotMovedToTheSuccessor(8_667_733_200);
    }

    function test_WrapUnderAReusedAttestedHotkey_StakesTheShareAtTheSuccessor() public {
        _reuseTheDrainedAttestedHotkeyAfterItsRecordedHotkeyRetires();

        _depositSixAlphaAndWrapUnder(hotkey1);

        _assertSlotMovedToTheSuccessor(8_667_733_200);
    }

    function test_ReusedAttestedHotkeyUnderOneColdkey_StakesTheShareAtTheSuccessor() public {
        _attestUnderOneColdkey(_hotkeys(hotkey1, hotkey2));
        _reuseTheDrainedAttestedHotkeyAfterItsRecordedHotkeyRetires();

        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].stakedUnder, hotkey5, "the emptied slot answers under the successor");
        assertEq(slots[1].stakedUnder, hotkey1, "the reused hotkey stays with the slot that holds it");
        assertEq(_realBacking(), OTHER_TWO_SLOTS, "moving the share created and lost nothing");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the backing is counted once");
    }

    function test_RevertWhen_ReusedAttestedHotkeyUnderOneColdkeyHasAnOwnerlessSuccessor() public {
        _attestUnderOneColdkey(_hotkeys(hotkey1, hotkey2));
        _reuseTheDrainedAttestedHotkeyAfterItsRecordedHotkeyRetires();
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey5, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
    }

    function test_AReusedAttestedHotkeysSuccessorClaimedByAStranger_StillCarriesTheSlot() public {
        _reuseTheDrainedAttestedHotkeyAfterItsRecordedHotkeyRetires();
        _simulateSquatter(hotkey5);

        vault.rebalance(NETUID1);

        assertEq(
            vault.recordedSlots(TOKEN1)[0].stakedUnder,
            hotkey5,
            "the slot answers under the successor, whoever holds it"
        );
        assertEq(_getVaultStake(hotkey5, NETUID1), REFILLED_FIRST_SLOT, "3334 bps of the remaining 19.998 alpha");
    }

    function _reusedAttestedHotkeysSuccessorHeldByAThirdSlot() private {
        _attestUnderOneColdkey(_hotkeys(hotkey1, hotkey2, hotkey3));
        _reuseTheDrainedAttestedHotkeyAfterItsRecordedHotkeyRetires();
        _simulateFollowedSwap(NETUID1, hotkey3, hotkey5);
    }

    function test_RevertWhen_AnAlphaRailMeetsAReusedAttestedHotkeysSuccessorHeldByAThirdSlot() public {
        _reusedAttestedHotkeysSuccessorHeldByAThirdSlot();
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
    }

    function test_ReusedAttestedHotkeysSuccessorHeldByAThirdSlot_LeavesTheTaoExitOpen() public {
        _reusedAttestedHotkeysSuccessorHeldByAThirdSlot();
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 taoBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);

        assertEq(alice.balance - taoBefore, 249_975_000 * 1e9, "4.9995 alpha sold at 0.05 TAO/alpha");
        assertEq(vault.balanceOf(alice, TOKEN1), 1.49985e19, "three quarters of the 1.9998e19 shares remain");
    }

    function _twoAttestedHotkeysSwappedOntoOneReusedHotkey() private returns (uint256 shares) {
        bytes32 reusedHotkey = keccak256("reused-hotkey");
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey5, hotkey3), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, reusedHotkey);
        _simulateFollowedSwap(NETUID1, reusedHotkey, keccak256("onward-hotkey"));
        _simulateFollowedSwap(NETUID1, hotkey5, reusedHotkey);
    }

    function test_RevertWhen_TwoAttestedHotkeysResolveToOneReusedHotkey() public {
        uint256 shares = _twoAttestedHotkeysSwappedOntoOneReusedHotkey();

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        _wrapHotkey(bob, NETUID1, hotkey3);
    }

    function test_TwoAttestedHotkeysOnOneReusedHotkey_LeaveTheTaoExitOpen() public {
        uint256 shares = _twoAttestedHotkeysSwappedOntoOneReusedHotkey();

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);

        assertEq(alice.balance, 0.375e18, "7.5 alpha sold at 0.05 TAO/alpha");
        assertEq(vault.balanceOf(alice, TOKEN1), 2.25e19, "three quarters of the 3e19 shares remain");
    }

    function _swapTheDrainedHotkeyBackOntoItsReusedAttestedHotkey() private {
        _attestUnderOneColdkey(_hotkeys(hotkey1, hotkey2));
        _positionWithADrainedSwap(hotkey4);
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey1);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey1);
    }

    function test_RevertWhen_AnAlphaRailMeetsADrainedHotkeySwappedBackOntoItsReusedAttestedHotkey() public {
        _swapTheDrainedHotkeyBackOntoItsReusedAttestedHotkey();
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        _wrapHotkey(bob, NETUID1, hotkey3);
    }

    function test_DrainedHotkeySwappedBackOntoItsReusedAttestedHotkey_PaysAFullExitFromRealBacking() public {
        _swapTheDrainedHotkeyBackOntoItsReusedAttestedHotkey();
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), OTHER_TWO_SLOTS, "the full exit pays what is really staked");
        assertEq(_realBacking(), 0, "and nothing more");
    }

    function _attestUnderOneColdkey(bytes32[] memory sharing) private {
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        for (uint256 i = 1; i < sharing.length; ++i) {
            staking.setHotkeyOwner(sharing[i], staking.ownerOf(sharing[0]));
        }
        _setValidators(
            NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
    }

    function _reuseTheDrainedAttestedHotkeyAfterItsRecordedHotkeyRetires() private {
        _positionWithADrainedSwap(hotkey4);
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey1);
    }

    function _depositSixAlphaAndWrapUnder(bytes32 chosenHotkey) private {
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        _wrapHotkey(bob, NETUID1, chosenHotkey);

        assertEq(vault.balanceOf(bob, TOKEN1), 6e18, "6 alpha against 19.998 alpha on 1.9998e19 shares");
        assertEq(_realBacking(), 25_998_000_000, "and the whole deposit is staked");
    }

    function _assertSlotMovedToTheSuccessor(uint256 successorStake) private view {
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey5, "the slot answers under the successor");
        assertEq(_getVaultStake(hotkey5, NETUID1), successorStake, "which is where its share went");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing was aimed at the retired hotkey");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for the backing once");
    }

    function _realBacking() private view returns (uint256) {
        return _userStakeAcrossHotkeys(_subnetColdkey(NETUID1), NETUID1);
    }

    function _retiredEntryBesideAHeldHotkey() private returns (uint256 shares) {
        _setValidators(NETUID1, _hotkeys(hotkey2), _weights(BPS_BASE));
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey2), _weights(5000, 5000));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey5, true);
    }

    function test_RevertWhen_PartialUnwrapNeedsARetiredEntry() public {
        uint256 shares = _retiredEntryBesideAHeldHotkey();

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
    }

    function test_FullUnwrapBesideARetiredEntry_PaysFromTheHeldHotkeys() public {
        uint256 shares = _retiredEntryBesideAHeldHotkey();

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0, "the whole position was burned");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 30 * ALPHA, "and paid out as staked alpha");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "leaving nothing behind");
    }

    function _fullPositionBesideARetiredEntry() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
    }

    function test_RevertWhen_FullUnwrapWouldRollStakeOntoARetiredEntry() public {
        uint256 shares = _fullPositionBesideARetiredEntry();

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
    }

    function test_RetiredEntry_LeavesTheFullTaoExitOpen() public {
        uint256 shares = _fullPositionBesideARetiredEntry();

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares, 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 0, "the TAO exit stays open");
        assertEq(alice.balance, 1.5e18, "30 alpha sold at 0.05 TAO/alpha");
    }

    function test_RevertWhen_RebalancingASetAttestingADrainedSwapAndItsSuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        _drainTheFirstSlot(alice, NETUID1);

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_RebalancingASetAttestingADrainedHotkeyAndItsUnrecordedSuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _drainTheFirstSlot(alice, NETUID1);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
    }

    function _setAttestingADrainedSwapBesideItsOwnedAttestedHotkey() private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));
        _drainTheFirstSlot(alice, NETUID1);
    }

    function test_RevertWhen_RebalancingASetAttestingADrainedSwapBesideItsOwnedAttestedHotkey() public {
        _setAttestingADrainedSwapBesideItsOwnedAttestedHotkey();

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
    }

    function test_SetAttestingADrainedSwapBesideItsOwnedAttestedHotkey_ResumesOnceTheOldAttestedHotkeyIsDropped()
        public
    {
        _setAttestingADrainedSwapBesideItsOwnedAttestedHotkey();

        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey2), _weights(5000, 5000));
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "dropping the old attested hotkey resumes service");
        assertEq(lens.totalStake(TOKEN1), OTHER_TWO_SLOTS, "with the 19.998 alpha the drain left");
    }

    function testFuzz_DrainedSwap_LeavesEverySlotOnItsOwnHotkey(uint256 rawCount) public {
        uint256 count = bound(rawCount, 2, MAX_VALIDATORS);
        (bytes32[] memory hotkeys, uint256 tokenId) = _wideSetPosition(count, 30 * ALPHA);
        uint256 drained = _getVaultStake(hotkeys[0], WIDE_SET_NETUID);

        bytes32 successor = keccak256("drained-swap-successor");
        _simulateFollowedSwap(WIDE_SET_NETUID, hotkeys[0], successor);
        vault.rebalance(WIDE_SET_NETUID);
        _drainTheFirstSlot(alice, WIDE_SET_NETUID);

        vault.rebalance(WIDE_SET_NETUID);

        _assertSlotsOnDistinctHotkeys(tokenId);
        uint256 underTheRecord = _vaultStakeAcross(_lastSeen(tokenId), WIDE_SET_NETUID);
        assertEq(underTheRecord, 30 * ALPHA - drained, "the drain sold the first slot's even share and nothing else");
        assertEq(underTheRecord, lens.totalStake(tokenId), "the record's hotkeys hold the whole position");
        assertEq(
            underTheRecord,
            _vaultStakeAcross(hotkeys, WIDE_SET_NETUID) + _getVaultStake(successor, WIDE_SET_NETUID),
            "and nothing of it was left outside them"
        );
    }

    function test_Emissions_DoNotTrip() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateEmissions(NETUID1, 5 * ALPHA);
        vault.rebalance(NETUID1);
        assertEq(lens.totalStake(TOKEN1), 35 * ALPHA, "emission counted, no false trip");
    }

    function test_OperationSequence_NeverTrips() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 60 * ALPHA);
        vault.rebalance(NETUID1);
        _depositAndWrap(bob, NETUID1, 25 * ALPHA);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares / 3, _toSubstrate(alice), 0);
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, aliceShares / 3, 0);
        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the record settled through the whole sequence");
        assertEq(lens.totalStake(TOKEN1), 45 * ALPHA, "85 alpha less two 20 alpha exits");
    }

    function test_Withdrawal_ReanchorsTheRecord() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].tracked, 4_999_500_000, "the emptied first slot expects the 4.9995 alpha hotkey3 gave up");
        assertEq(slots[1].tracked, 5_001_000_000, "the paying slot expects 20.001 alpha less the 15 alpha exit");
        assertEq(slots[2].tracked, 4_999_500_000, "the third slot expects its 3333 bps of 15 alpha");
        for (uint256 i; i < slots.length; ++i) {
            assertEq(slots[i].tracked, _getVaultStake(slots[i].stakedUnder, NETUID1), "expectation matches the ledger");
        }
    }

    function test_SwapAfterWithdrawal_IsStillFollowed() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "an ordinary swap after an exit is still followable");
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the record moved to the successor");
    }

    function test_SwapAfterTaoExit_StaysOperable() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 2, 0);

        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the TAO rail leaves a record the swap cannot trip");
        vault.rebalance(NETUID1);
        assertEq(lens.totalStake(TOKEN1), 15 * ALPHA, "backing whole across the swap");
    }

    function test_MoveRounding_IsBookedAtTheLandedAmount() public {
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(100);
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        assertEq(vault.recordedSlots(TOKEN1)[1].tracked, 9_998_999_900, "the slot expects what landed");
        assertEq(lens.totalStake(TOKEN1), 29_999_999_800, "two alignment moves each lose 100 RAO");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the loss trips nothing");
    }

    function testFuzz_WideSet_FollowsASwap(uint256 rawCount) public {
        uint256 count = bound(rawCount, 2, MAX_VALIDATORS);
        (bytes32[] memory hotkeys, uint256 tokenId) = _wideSetPosition(count, 10 * ALPHA);
        uint256 firstSlot = _getVaultStake(hotkeys[0], WIDE_SET_NETUID);

        bytes32 successor = keccak256("wide-set-successor");
        _simulateFollowedSwap(WIDE_SET_NETUID, hotkeys[0], successor);
        vault.rebalance(WIDE_SET_NETUID);

        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        assertEq(slots.length, count, "one slot per attested validator");
        assertEq(slots[0].attested, hotkeys[0], "the registry still attests the swapped validator");
        assertEq(slots[0].stakedUnder, successor, "whose alpha is tracked at the successor");
        assertEq(_getVaultStake(hotkeys[0], WIDE_SET_NETUID), 0, "nothing stays under the swapped hotkey");
        assertEq(_getVaultStake(successor, WIDE_SET_NETUID), firstSlot, "the successor holds the first slot's stake");
        assertEq(lens.totalStake(tokenId), 10 * ALPHA, "backing whole across the wide set");
        assertTrue(lens.isBackingIntact(tokenId), "record sound after the follow");
    }
}
