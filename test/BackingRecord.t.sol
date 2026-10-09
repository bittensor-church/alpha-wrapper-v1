// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { AttestedHotkeyRetired, ZeroAmount } from "src/VaultErrors.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract BackingRecordTest is AlphaVaultTestBase {
    function test_Wrap_RecordsWhereEachValidatorsAlphaIs() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 3, "one slot per attested validator");
        assertEq(slots[0].logical, hotkey1, "the slot names the attested validator");
        assertEq(slots[0].active, hotkey1, "with nothing swapped the two agree");
        assertEq(slots[0].tracked, 10_002_000_000, "the expectation is the slot's 3334 bps of 30 alpha");
        assertEq(lens.writeOffDeadline(TOKEN1), 0, "and no clock is running");
    }

    function test_IntactSlot_NeverReadsASuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setHotkeySuccessor(hotkey1, NETUID1, hotkey5);

        vault.rebalance(NETUID1);

        assertTrue(lens.isBackingIntact(TOKEN1), "the slot answered from its own balance");
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "and nothing moved the record");
    }

    function test_DirectSwap_MovesActiveAndLeavesLogicalAlone() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "the quote resolves the swap before any write");
        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].logical, hotkey1, "the registry still names the original validator");
        assertEq(slots[0].active, hotkey4, "the alpha is tracked at the successor");
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
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);

        assertTrue(lens.isBackingIntact(tokenId), "the quote reads the position as sound");
        vault.rebalance(netuid);

        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        assertEq(slots[0].logical, hotkey1, "the registry has not moved");
        assertEq(slots[0].active, hotkey5, "the alpha is tracked at the live key");
        assertEq(lens.lastSeenHotkeys(tokenId)[0], hotkey5, "the lens reports the same key");
        assertEq(lens.totalStake(tokenId), 10 * ALPHA, "backing whole across both swaps");
    }

    function test_SwappedValidator_AllRailsKeepWorking() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 shares = _depositAndWrap(bob, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey4);
        vm.expectRevert(ZeroAmount.selector);
        _wrapHotkey(alice, NETUID1, hotkey1);
        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, _toSubstrate(alice));
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey2);
        _wrapHotkey(alice, NETUID1, hotkey2);
        vm.prank(bob);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(bob), 0);
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
        vault.rebalance(NETUID1);

        assertEq(
            _getStakeForColdkey(hotkey4, _toSubstrate(bob), NETUID1), 15 * ALPHA, "the alpha exit paid at the successor"
        );
        assertEq(bob.balance, 0.375e18, "the TAO exit sold 7.5 alpha at 0.05 TAO/alpha");
        assertEq(lens.totalStake(TOKEN1), 47_500_000_000, "70 alpha less both exits");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing staked toward the retired key");
        assertTrue(lens.isBackingIntact(TOKEN1), "record sound throughout");
    }

    function test_ReorderedSet_KeepsWeightsWithTheirValidators() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        // Per-subnet swapping retains the old owner, allowing the reordered attestation.
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey3, hotkey1, hotkey2), _weights(5000, 3000, 2000));
        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].logical, hotkey3, "slot order follows the attested set");
        assertEq(slots[1].logical, hotkey1, "the swapped validator kept its own weight slot");
        assertEq(slots[1].active, hotkey4, "and its alpha is still tracked at the successor");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "nothing lost in the reorder");
    }

    function test_DroppedValidator_HasItsAlphaRolledOntoTheNewSet() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey2, hotkey3), _weights(5000, 5000));
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the successor was drained");
        assertEq(vault.recordedSlots(TOKEN1).length, 2, "the record matches the new set");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "backing whole after the roll");
    }

    function test_SetNamingTheSuccessor_CountsTheBalanceOnce() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].logical, hotkey4, "the attested name took over the slot");
        assertEq(slots[0].active, hotkey4, "answering for its own key");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "and nothing is counted twice");
    }

    function test_SetNamingASwappedKeyAndItsSuccessor_RefusesAlphaRailsUntilDropped() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);

        // Install the set before the swap removes ownership; ownerless entries cannot be newly attested.
        _setValidators(
            NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);

        _setValidators(
            NETUID1, _hotkeys(hotkey4, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "dropping the stale name resumes service");
    }

    /// @dev Leaves 19.998 alpha on hotkey2 and hotkey3 behind 1.9998e19 shares, with the first slot
    ///      emptied on the successor hotkey4.
    function _positionWithADrainedSwap() private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _drainTheFirstSlot(alice, NETUID1);
    }

    function test_RebalanceAfterADrainedSwap_StakesTheShareAtTheSuccessor() public {
        _positionWithADrainedSwap();

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the slot answers under the successor");
        assertEq(_getVaultStake(hotkey4, NETUID1), 6_667_333_200, "3334 bps of the remaining 19.998 alpha");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "and nothing was aimed at the retired name");
    }

    function test_UnwrapAfterADrainedSwap_StakesTheShareAtTheSuccessor() public {
        _positionWithADrainedSwap();

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the slot answers under the successor");
        // Alignment moves 4.99999995 alpha from hotkey3; the remaining 499,950 RAO move is below the floor.
        assertEq(_getVaultStake(hotkey4, NETUID1), 4_999_999_950, "which is where its share went");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 4_999_500_000, "the exit delivered a quarter");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for what is left");
    }

    function test_WrapAfterADrainedSwap_StakesTheShareAtTheSuccessor() public {
        _positionWithADrainedSwap();

        _simulateAlphaDepositHotkey(bob, NETUID1, 6 * ALPHA, hotkey2);
        _wrapHotkey(bob, NETUID1, hotkey2);

        assertEq(vault.balanceOf(bob, TOKEN1), 6e18, "6 alpha against 19.998 alpha on 1.9998e19 shares");
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the slot answers under the successor");
        assertEq(_getVaultStake(hotkey4, NETUID1), 8_667_733_200, "3334 bps of 25.998 alpha");
    }

    function test_ValidatorSwappingBeforeItIsFunded_StakesItsShareAtTheSuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);

        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[2].logical, hotkey4, "the record names the attested validator");
        assertEq(slots[2].active, hotkey5, "while its share sits at the successor");
        assertEq(_getVaultStake(hotkey5, NETUID1), 9_999_000_000, "which is where the rebalance staked it");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "backing whole across the swap");
    }

    function test_PerSubnetSwapAfterADrain_StakesTheShareAtTheAttestedName() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _drainTheFirstSlot(alice, NETUID1);

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey1, "the slot answers under its own name again");
        assertEq(_getVaultStake(hotkey1, NETUID1), 6_667_333_200, "3334 bps of the remaining 19.998 alpha");
    }

    function _retiredNameWithNoSuccessor() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey4, true);
    }

    function test_RevertWhen_AnAlphaRailMeetsARetiredNameWithNoSuccessor() public {
        uint256 shares = _retiredNameWithNoSuccessor();

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vault.rebalance(NETUID1);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        _simulateAlphaDepositHotkey(bob, NETUID1, 6 * ALPHA, hotkey2);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        _wrapHotkey(bob, NETUID1, hotkey2);
    }

    function test_RetiredNameWithNoSuccessor_LeavesTheTaoExitOpen() public {
        uint256 shares = _retiredNameWithNoSuccessor();

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);

        assertEq(alice.balance, 0.375e18, "7.5 alpha sold at 0.05 TAO/alpha");
        assertEq(vault.balanceOf(alice, TOKEN1), shares - shares / 4);
    }

    function test_RetiredNameWithARetiredSuccessor_RefusesTheRebalance() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey5, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vault.rebalance(NETUID1);
    }

    function _positionWithTwoFollowedSwapsThenADrain() private {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey5, "the record followed both swaps");
        _drainTheFirstSlot(alice, NETUID1);
    }

    /// @dev The logical name's edge still points to the first successor, not the latest recorded key.
    function test_RebalanceAfterTwoFollowedSwapsAndADrain_StakesTheShareAtTheRecordedKey() public {
        _positionWithTwoFollowedSwapsThenADrain();

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey5, "the slot stays on the key it was found under");
        assertEq(_getVaultStake(hotkey5, NETUID1), 6_667_333_200, "3334 bps of the remaining 19.998 alpha");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing was aimed at the retired successor");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for everything");
    }

    function test_UnwrapAfterTwoFollowedSwapsAndADrain_StakesTheShareAtTheRecordedKey() public {
        _positionWithTwoFollowedSwapsThenADrain();

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey5, "the slot stays on the key it was found under");
        assertEq(_getVaultStake(hotkey5, NETUID1), 4_999_999_950, "which is where its share went");
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 4_999_500_000, "the exit delivered a quarter");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for what is left");
    }

    function test_RebalanceAfterAReusedName_StakesTheShareAtTheSuccessor() public {
        _reuseTheDrainedNameAfterItsRecordedKeyRetires();

        vault.rebalance(NETUID1);

        _assertSlotMovedToTheSuccessor(6_667_333_200);
        assertEq(_realBacking(), 19_998_000_000, "moving the share created and lost nothing");
    }

    function test_UnwrapAfterAReusedName_StakesTheShareAtTheSuccessor() public {
        _reuseTheDrainedNameAfterItsRecordedKeyRetires();
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);

        assertEq(_stakeAcrossAllHotkeys(_toSubstrate(alice)), 4_999_500_000, "a quarter of 19.998 alpha");
        assertEq(_realBacking(), 14_998_500_000, "and the rest stays staked");
        _assertSlotMovedToTheSuccessor(4_999_999_950);
    }

    function test_WrapAfterAReusedName_StakesTheShareAtTheSuccessor() public {
        _reuseTheDrainedNameAfterItsRecordedKeyRetires();

        _depositSixAlphaAndWrapUnder(hotkey3);

        _assertSlotMovedToTheSuccessor(8_667_733_200);
    }

    function test_WrapUnderAReusedName_StakesTheShareAtTheSuccessor() public {
        _reuseTheDrainedNameAfterItsRecordedKeyRetires();

        _depositSixAlphaAndWrapUnder(hotkey1);

        _assertSlotMovedToTheSuccessor(8_667_733_200);
    }

    function test_ReusedAttestedNameUnderOneColdkey_StakesTheShareAtTheSuccessor() public {
        _attestUnderOneColdkey(_hotkeys(hotkey1, hotkey2));
        _reuseTheDrainedNameAfterItsRecordedKeyRetires();

        vault.rebalance(NETUID1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots[0].active, hotkey5, "the emptied slot answers under the successor");
        assertEq(slots[1].active, hotkey1, "the reused name stays with the slot that holds it");
        assertEq(_realBacking(), 19_998_000_000, "moving the share created and lost nothing");
        assertTrue(lens.isBackingIntact(TOKEN1), "and the backing is counted once");
    }

    function test_RevertWhen_ReusedNameUnderOneColdkeyHasNoLiveKey() public {
        _attestUnderOneColdkey(_hotkeys(hotkey1, hotkey2));
        _reuseTheDrainedNameAfterItsRecordedKeyRetires();
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey5, true);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_AReusedNamesSuccessorBelongsToAStranger() public {
        _reuseTheDrainedNameAfterItsRecordedKeyRetires();
        _simulateSquatter(hotkey5);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
    }

    function _reusedNamesSuccessorHeldByAThirdSlot() private {
        _attestUnderOneColdkey(_hotkeys(hotkey1, hotkey2, hotkey3));
        _reuseTheDrainedNameAfterItsRecordedKeyRetires();
        _simulateFollowedSwap(NETUID1, hotkey3, hotkey5);
    }

    function test_RevertWhen_AnAlphaRailMeetsAReusedNamesSuccessorHeldByAThirdSlot() public {
        _reusedNamesSuccessorHeldByAThirdSlot();
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
    }

    function test_ReusedNamesSuccessorHeldByAThirdSlot_LeavesTheTaoExitOpen() public {
        _reusedNamesSuccessorHeldByAThirdSlot();
        uint256 shares = vault.balanceOf(alice, TOKEN1);
        uint256 taoBefore = alice.balance;

        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);

        assertEq(alice.balance - taoBefore, 249_975_000 * 1e9, "4.9995 alpha sold at 0.05 TAO/alpha");
        assertEq(vault.balanceOf(alice, TOKEN1), shares - shares / 4, "the TAO exit stays open");
    }

    function _swapTheDrainedKeyBackOntoItsReusedName() private {
        _attestUnderOneColdkey(_hotkeys(hotkey1, hotkey2));
        _positionWithADrainedSwap();
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey1);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey1);
    }

    function test_RevertWhen_AnAlphaRailMeetsADrainedKeySwappedBackOntoItsReusedName() public {
        _swapTheDrainedKeyBackOntoItsReusedName();
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vault.rebalance(NETUID1);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 4, _toSubstrate(alice), 0);
        _simulateAlphaDepositHotkey(bob, NETUID1, 6 * ALPHA, hotkey3);
        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey1));
        _wrapHotkey(bob, NETUID1, hotkey3);
    }

    function test_DrainedKeySwappedBackOntoItsReusedName_PaysAFullExitFromRealBacking() public {
        _swapTheDrainedKeyBackOntoItsReusedName();
        uint256 shares = vault.balanceOf(alice, TOKEN1);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(
            _stakeAcrossAllHotkeys(_toSubstrate(alice)), 19_998_000_000, "the full exit pays what is really staked"
        );
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

    /// @dev hotkey1 now holds the second slot's 9.999 alpha while the first slot's record names the
    ///      retired hotkey4, whose successor is hotkey5.
    function _reuseTheDrainedNameAfterItsRecordedKeyRetires() private {
        _positionWithADrainedSwap();
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        _simulateFollowedSwap(NETUID1, hotkey2, hotkey1);
    }

    function _depositSixAlphaAndWrapUnder(bytes32 chosenHotkey) private {
        _simulateAlphaDepositHotkey(bob, NETUID1, 6 * ALPHA, chosenHotkey);
        _wrapHotkey(bob, NETUID1, chosenHotkey);

        assertEq(vault.balanceOf(bob, TOKEN1), 6e18, "6 alpha against 19.998 alpha on 1.9998e19 shares");
        assertEq(_realBacking(), 25_998_000_000, "and the whole deposit is staked");
    }

    function _assertSlotMovedToTheSuccessor(uint256 successorStake) private view {
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey5, "the slot answers under the successor");
        assertEq(_getVaultStake(hotkey5, NETUID1), successorStake, "which is where its share went");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "and nothing was aimed at the retired key");
        assertTrue(lens.isBackingIntact(TOKEN1), "with the record accounting for the backing once");
    }

    function _stakeAcrossAllHotkeys(bytes32 coldkey) private view returns (uint256 total) {
        total = _getStakeForColdkey(hotkey1, coldkey, NETUID1) + _getStakeForColdkey(hotkey2, coldkey, NETUID1)
            + _getStakeForColdkey(hotkey3, coldkey, NETUID1) + _getStakeForColdkey(hotkey4, coldkey, NETUID1)
            + _getStakeForColdkey(hotkey5, coldkey, NETUID1);
    }

    function _realBacking() private view returns (uint256) {
        return _stakeAcrossAllHotkeys(_subnetColdkey(NETUID1));
    }

    function _retiredEntryBesideAHeldKey() private returns (uint256 shares) {
        _setValidators(NETUID1, _hotkeys(hotkey2), _weights(VaultMath.BPS_BASE));
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey2), _weights(5000, 5000));
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey5, true);
    }

    function test_RevertWhen_PartialUnwrapNeedsARetiredEntry() public {
        uint256 shares = _retiredEntryBesideAHeldKey();

        vm.expectRevert(abi.encodeWithSelector(AttestedHotkeyRetired.selector, hotkey4));
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
    }

    function test_FullUnwrapBesideARetiredEntry_PaysFromTheHeldKeys() public {
        uint256 shares = _retiredEntryBesideAHeldKey();

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

    function test_SetNamingADrainedSwapAndItsSuccessor_StillRefuses() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
        _drainTheFirstSlot(alice, NETUID1);

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);
    }

    function test_SetNamingADrainedSwapBesideItsLiveName_StillRefuses() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4, hotkey2), _weights(3334, 3333, 3333));
        _drainTheFirstSlot(alice, NETUID1);

        vm.expectRevert(IAlphaVaultAbi.SwappedHotkeyStillAttested.selector);
        vault.rebalance(NETUID1);

        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey2), _weights(5000, 5000));
        vault.rebalance(NETUID1);
        assertTrue(lens.isBackingIntact(TOKEN1), "dropping the old name resumes service");
    }

    function testFuzz_DrainedSwap_LeavesEverySlotOnItsOwnKey(uint256 rawCount) public {
        uint256 count = bound(rawCount, 2, 8);
        uint256 netuid = 11;
        _setRegBlock(netuid, 500);
        bytes32[] memory hks = _setValidatorCount(netuid, count);
        _simulateAlphaDepositHotkey(alice, netuid, 30 * ALPHA, hks[0]);
        _wrapHotkey(alice, netuid, hks[0]);
        uint256 tokenId = vault.currentTokenId(netuid);

        bytes32 successor = keccak256("drained-swap-successor");
        _simulateFollowedSwap(netuid, hks[0], successor);
        vault.rebalance(netuid);
        _drainTheFirstSlot(alice, netuid);

        vault.rebalance(netuid);

        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i].active != slots[j].active, "no two slots answer for one key");
            }
        }
        uint256 underTheRecord = _vaultStakeAcross(_lastSeen(tokenId), netuid);
        assertEq(underTheRecord, lens.totalStake(tokenId), "the record's keys hold the whole position");
        assertEq(
            underTheRecord,
            _vaultStakeAcross(hks, netuid) + _getVaultStake(successor, netuid),
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
        for (uint256 i; i < slots.length; ++i) {
            assertEq(slots[i].tracked, _getVaultStake(slots[i].active, NETUID1), "expectation matches the ledger");
        }
    }

    function test_SwapAfterWithdrawal_IsStillFollowed() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);

        assertTrue(lens.isBackingIntact(TOKEN1), "an ordinary swap after an exit is still followable");
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].active, hotkey4, "the record moved to the successor");
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
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory hks = _setValidatorCount(netuid, count);

        _simulateAlphaDepositHotkey(alice, netuid, MAX_VALIDATORS * ALPHA, hks[0]);
        _wrapHotkey(alice, netuid, hks[0]);
        uint256 tokenId = vault.currentTokenId(netuid);

        bytes32 swapped = keccak256("wide-set-successor");
        _simulateFollowedSwap(netuid, hks[0], swapped);
        vault.rebalance(netuid);

        assertEq(lens.totalStake(tokenId), MAX_VALIDATORS * ALPHA, "backing whole across the wide set");
        assertTrue(lens.isBackingIntact(tokenId), "record sound after the follow");
    }
}
