// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BackingScenarios } from "./helpers/BackingScenarios.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract FollowedHotkeyRetakenTest is BackingScenarios {
    bytes32 internal constant JUNK = keccak256("stranger-junk-hotkey");
    bytes32 internal constant STRANGER_NEXT = keccak256("stranger-next-hotkey");

    uint256 internal constant FIRST_DEPOSIT = 3_000 * ALPHA;
    uint256 internal constant LATER_DEPOSIT = 600 * ALPHA;
    uint256 internal constant FIRST_SLOT_AFTER_DRAIN = 666_733_320_000;
    uint256 internal constant FIRST_SLOT_AFTER_DEPOSIT = 866_773_320_000;
    uint256 internal constant BACKING_AFTER_DRAIN = 1_999_800_000_000;

    function _validatorSwapsOnTheSubnetAndTheVaultFollows() private {
        _simulatePerSubnetSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the vault followed the validator's swap");
    }

    function _validatorSwapsOnFromTheFollowedHotkey() private {
        _simulateFollowedSwap(NETUID1, hotkey4, hotkey5);
        assertEq(_hotkeyOwner(hotkey5), _hotkeyOwner(hotkey1), "same validator coldkey");
    }

    function _strangerSwapsJunkHotkeyIntoTheFollowedHotkey() private {
        MockStaking mock = MockStaking(STAKING_PRECOMPILE);
        mock.clearHotkeySuccessor(hotkey4, NETUID1);
        mock.setHotkeySuccessor(JUNK, NETUID1, hotkey4);
    }

    function _strangerRetakesTheFollowedHotkey() private {
        _simulateSquatter(hotkey4);
        _strangerSwapsJunkHotkeyIntoTheFollowedHotkey();
        assertEq(_hotkeyOwner(hotkey4), _squatterColdkey(hotkey4), "owned by the stranger");
    }

    function _alphaHeldBy(address holder) private view returns (uint256) {
        return _userStakeAcrossHotkeys(holder, NETUID1) + _getStake(STRANGER_NEXT, holder, NETUID1);
    }

    function _publishTheValidatorsCurrentHotkey() private {
        _setValidators(
            NETUID1, _hotkeys(hotkey5, hotkey2, hotkey3), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3)
        );
    }

    function _setUpEmptiedFollowedSlotThenSecondSwap() internal {
        _depositAndWrap(alice, NETUID1, FIRST_DEPOSIT);
        _validatorSwapsOnTheSubnetAndTheVaultFollows();
        _drainTheFirstSlot(alice, NETUID1);
        assertEq(vault.recordedSlots(TOKEN1)[0].tracked, 0, "slot 0 is empty");
        _validatorSwapsOnFromTheFollowedHotkey();
    }

    function _setUpRetakenFollowedHotkeyHoldingItsWeight() private {
        _setUpEmptiedFollowedSlotThenSecondSwap();
        _strangerRetakesTheFollowedHotkey();
        _depositAndWrap(bob, NETUID1, LATER_DEPOSIT);
        assertEq(
            _getVaultStake(hotkey4, NETUID1),
            FIRST_SLOT_AFTER_DEPOSIT,
            "3334 bps of 2,599.8 alpha sit on the retaken hotkey"
        );
    }

    function _setUpRetakenFollowedHotkeyOnAnIdleToken() private {
        uint256 shares = _depositAndWrap(alice, NETUID1, FIRST_DEPOSIT);
        _validatorSwapsOnTheSubnetAndTheVaultFollows();
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(lens.totalStake(TOKEN1), 0, "the full exit left nothing behind");
        _validatorSwapsOnFromTheFollowedHotkey();
        _strangerRetakesTheFollowedHotkey();
    }

    function test_Control_EmptiedSlotGoesToValidatorHeldAttestedHotkey() public {
        _setUpEmptiedFollowedSlotThenSecondSwap();

        vault.rebalance(NETUID1);

        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey1, "routed to the validator's attested hotkey");
        assertEq(
            _getVaultStake(hotkey1, NETUID1),
            FIRST_SLOT_AFTER_DRAIN,
            "3334 bps of 1,999.8 alpha on the validator's hotkey"
        );
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "nothing on the hotkey the validator left");
        assertEq(
            _getVaultStake(hotkey5, NETUID1),
            0,
            "nothing on the validator's current hotkey before the registry attests it"
        );
    }

    function test_StrangerClaimingTheVacatedFollowedHotkey_ReceivesNothingWhileItsSwapEdgeStands() public {
        _setUpEmptiedFollowedSlotThenSecondSwap();
        _simulateSquatter(hotkey4);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the claimed hotkey receives nothing");
        assertEq(
            _getVaultStake(hotkey1, NETUID1),
            FIRST_SLOT_AFTER_DRAIN,
            "the slot's weight goes to the validator's attested hotkey"
        );
        assertEq(
            vault.recordedSlots(TOKEN1)[0].stakedUnder,
            hotkey1,
            "the slot answers under the validator's attested hotkey"
        );
    }

    function test_StrangerRetakingTheFollowedHotkeyAndClearingItsSwapEdge_CarriesTheEmptiedSlot() public {
        _setUpEmptiedFollowedSlotThenSecondSwap();
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);
        assertEq(lens.totalStake(TOKEN1), BACKING_AFTER_DRAIN, "3,000 alpha less the drained 1,000.2");

        _strangerRetakesTheFollowedHotkey();
        vault.rebalance(NETUID1);

        VaultReads.Slot memory slot0 = vault.recordedSlots(TOKEN1)[0];
        assertEq(slot0.attested, hotkey1, "the registry still attests the validator's hotkey1");
        assertEq(slot0.stakedUnder, hotkey4, "but the slot is now staked under the stranger's hotkey");
        assertEq(slot0.tracked, FIRST_SLOT_AFTER_DRAIN, "the record tracks the retaken allocation");
        assertEq(_getVaultStake(hotkey4, NETUID1), FIRST_SLOT_AFTER_DRAIN, "3334 bps of 1,999.8 alpha delegated to it");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing reaches the validator-held attested hotkey");
        assertEq(_getVaultStake(hotkey5, NETUID1), 0, "nothing reaches the validator's current hotkey");

        assertEq(lens.totalStake(TOKEN1), BACKING_AFTER_DRAIN, "every RAO stays under the clone's coldkey");
        (uint256 aliceExitValue,) = lens.previewUnwrap(TOKEN1, aliceShares);
        assertEq(aliceExitValue, BACKING_AFTER_DRAIN, "the holder's exit value is untouched");

        _simulateAlphaDeposit(bob, NETUID1, LATER_DEPOSIT);
        _wrapHotkey(bob, NETUID1, hotkey1);
        assertEq(
            _getVaultStake(hotkey4, NETUID1),
            FIRST_SLOT_AFTER_DEPOSIT,
            "new deposits for hotkey1 land on the stranger's hotkey"
        );
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "and still nothing reaches hotkey1");
        assertEq(lens.totalStake(TOKEN1), 2_599_800_000_000, "the 600 alpha deposit is backing in full");
        assertTrue(lens.isBackingIntact(TOKEN1), "nothing looks wrong to the vault or the lens");
    }

    function test_RetakenFollowedHotkey_AllRailsKeepWorking() public {
        _setUpRetakenFollowedHotkeyOnAnIdleToken();

        assertEq(lens.previewWrap(TOKEN1, FIRST_DEPOSIT), 3e21, "the idle token quotes 1e9 shares per RAO");
        uint256 bobShares = _depositAndWrap(bob, NETUID1, FIRST_DEPOSIT);
        assertEq(bobShares, 3e21, "the wrap chosen under the attested hotkey mints the quote");
        assertEq(
            _getVaultStake(hotkey4, NETUID1), 1_000_200_000_000, "3334 bps of 3,000 alpha land on the retaken hotkey"
        );

        _simulateAlphaDeposit(alice, NETUID1, 1_000 * ALPHA);
        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, _toSubstrate(alice));
        _simulateAlphaDeposit(alice, NETUID1, 1_000 * ALPHA);
        _wrapHotkey(alice, NETUID1, hotkey1);

        (uint256 quotedAlpha,) = lens.previewUnwrap(TOKEN1, bobShares / 2);
        assertEq(quotedAlpha, 1_500 * ALPHA, "half of bob's 3,000 alpha");
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares / 2, _toSubstrate(bob), 0);
        assertEq(_userStakeAcrossHotkeys(bob, NETUID1), quotedAlpha, "the alpha exit paid the quote");

        (uint256 soldAlpha,) = lens.previewUnwrap(TOKEN1, bobShares / 4);
        assertEq(soldAlpha, 750 * ALPHA, "a quarter of bob's 3,000 alpha");
        vm.prank(bob);
        vault.unwrapForTao(TOKEN1, bobShares / 4, 0);
        assertEq(bob.balance, 37.5 ether, "750 alpha sold at 0.05 TAO/alpha");
        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), 1_750 * ALPHA, "4,000 alpha less the 1,500 and 750 alpha exits");
        assertEq(_getVaultStake(hotkey4, NETUID1), 583_450_000_000, "the retaken hotkey holds 3334 bps of 1,750 alpha");
        assertEq(
            _getVaultStake(hotkey4, NETUID1) + _getVaultStake(hotkey2, NETUID1) + _getVaultStake(hotkey3, NETUID1),
            lens.totalStake(TOKEN1),
            "every RAO sits under the clone's coldkey"
        );
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing is ever staked under the attested hotkey");
        assertEq(_getVaultStake(hotkey5, NETUID1), 0, "nor under the validator's current hotkey");
        assertTrue(lens.isBackingIntact(TOKEN1), "record sound throughout");
    }

    function test_PublishingTheValidatorsCurrentHotkey_MovesTheAllocationOffTheRetakenHotkey() public {
        _setUpRetakenFollowedHotkeyHoldingItsWeight();
        uint256 aliceShares = vault.balanceOf(alice, TOKEN1);
        uint256 bobShares = vault.balanceOf(bob, TOKEN1);

        _publishTheValidatorsCurrentHotkey();
        vm.expectEmit(address(vault));
        emit SlotRelocated(TOKEN1, 0, hotkey4, hotkey5);
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the retaken hotkey is consolidated away");
        assertEq(_getVaultStake(hotkey5, NETUID1), FIRST_SLOT_AFTER_DEPOSIT, "onto the validator's current hotkey");
        VaultReads.Slot memory slot0 = vault.recordedSlots(TOKEN1)[0];
        assertEq(slot0.attested, hotkey5, "the slot is attested under the validator's current hotkey");
        assertEq(slot0.stakedUnder, hotkey5, "and staked under it");
        assertEq(_hotkeyOwner(slot0.stakedUnder), _hotkeyOwner(hotkey1), "the validator's coldkey owns that hotkey");

        assertEq(lens.totalStake(TOKEN1), 2_599_800_000_000, "the move lost no backing");
        (uint256 aliceExitValue,) = lens.previewUnwrap(TOKEN1, aliceShares);
        (uint256 bobExitValue,) = lens.previewUnwrap(TOKEN1, bobShares);
        assertEq(aliceExitValue, BACKING_AFTER_DRAIN, "alice's 1,999.8 alpha exit value is untouched");
        assertEq(bobExitValue, LATER_DEPOSIT, "bob's 600 alpha exit value is untouched");
        assertTrue(lens.isBackingIntact(TOKEN1), "record sound after the move");

        _simulateAlphaDeposit(bob, NETUID1, LATER_DEPOSIT);
        _wrapHotkey(bob, NETUID1, hotkey5);
        assertEq(
            _getVaultStake(hotkey5, NETUID1), 1_066_813_320_000, "3334 bps of 3,199.8 alpha on the validator's hotkey"
        );
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "later deposits stay off the stranger's hotkey");
    }

    function test_RepublishingTheSameSet_LeavesTheAllocationOnTheRetakenHotkey() public {
        _setUpRetakenFollowedHotkeyHoldingItsWeight();

        _reattestValidators(NETUID1);
        vault.rebalance(NETUID1);

        assertEq(
            _getVaultStake(hotkey4, NETUID1), FIRST_SLOT_AFTER_DEPOSIT, "a funded slot stays on its recorded hotkey"
        );
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing returns to the attested hotkey");
        assertEq(vault.recordedSlots(TOKEN1)[0].stakedUnder, hotkey4, "the slot still answers under the stranger");
    }

    function testFuzz_PublishingTheValidatorsCurrentHotkey_ReturnsEveryDepositInFull(
        uint256 bobDeposit,
        uint256 aliceDeposit
    ) public {
        bobDeposit = bound(bobDeposit, ALPHA, 1_000_000 * ALPHA);
        aliceDeposit = bound(aliceDeposit, ALPHA, 1_000_000 * ALPHA);
        _setUpRetakenFollowedHotkeyOnAnIdleToken();
        uint256 bobShares = _depositAndWrap(bob, NETUID1, bobDeposit);
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, aliceDeposit);
        uint256 backing = bobDeposit + aliceDeposit;
        uint256 retaken = backing * 3334 / 10_000;
        assertEq(_getVaultStake(hotkey4, NETUID1), retaken, "the retaken hotkey holds the slot's weight");
        assertEq(_getVaultStake(hotkey1, NETUID1), 0, "nothing reaches the attested hotkey");

        _publishTheValidatorsCurrentHotkey();
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the retaken hotkey is consolidated away");
        assertEq(_getVaultStake(hotkey5, NETUID1), retaken, "onto the validator's current hotkey");
        assertEq(lens.totalStake(TOKEN1), backing, "the move lost no backing");

        uint256 aliceAlphaBefore = _userStakeAcrossHotkeys(alice, NETUID1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1) - aliceAlphaBefore, aliceDeposit, "alice exits in full");
        assertEq(_userStakeAcrossHotkeys(bob, NETUID1), bobDeposit, "bob exits in full");
        assertEq(lens.totalStake(TOKEN1), 0, "nothing is left behind");
    }

    function testFuzz_RetakenFollowedHotkeySwappedAwayWithoutATrail_EveryHolderExitsInFull(
        uint256 bobDeposit,
        uint256 aliceDeposit
    ) public {
        bobDeposit = bound(bobDeposit, ALPHA, 1_000_000 * ALPHA);
        aliceDeposit = bound(aliceDeposit, ALPHA, 1_000_000 * ALPHA);
        _setUpRetakenFollowedHotkeyOnAnIdleToken();
        uint256 bobShares = _depositAndWrap(bob, NETUID1, bobDeposit);
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, aliceDeposit);
        uint256 backing = bobDeposit + aliceDeposit;
        uint256 retaken = backing * 3334 / 10_000;

        _cutTheEdge(hotkey4, STRANGER_NEXT);

        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the stranger carried the slot's alpha off the retaken hotkey");
        assertEq(_getVaultStake(STRANGER_NEXT, NETUID1), retaken, "onto its next hotkey");
        assertTrue(lens.isBackingIntact(TOKEN1), "the staking list shows where the alpha went");
        assertEq(lens.totalStake(TOKEN1), backing, "no backing is missing");
        assertEq(lens.resolvedBacking(TOKEN1).hotkeys[0], STRANGER_NEXT, "the slot answers under the found hotkey");

        uint256 aliceAlphaBefore = _alphaHeldBy(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);

        assertEq(_alphaHeldBy(alice) - aliceAlphaBefore, aliceDeposit, "alice exits in full");
        assertEq(_alphaHeldBy(bob), bobDeposit, "bob exits in full");
        assertEq(lens.totalStake(TOKEN1), 0, "nothing is left behind");
    }
}
