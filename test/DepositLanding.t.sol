// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { DepositScenarios } from "./helpers/DepositScenarios.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import {
    AlphaTransfersDisabled,
    ShortfallOnFile,
    SlippageExceeded,
    StakingListHasRoom,
    SubnetCloneNotPrepared,
    SubnetDissolved,
    SubnetInDissolutionBlackoutPeriod
} from "src/VaultErrors.sol";

contract DepositLandingTest is DepositScenarios {
    bytes32 private constant FRESH_UID = keccak256("fresh-clone-uid");
    uint256 private constant REPLACEMENT_OPENS_AT = 128;

    function _sendToMailbox(address user, uint256 netuid, bytes32 fromHotkey, uint256 amount) private {
        _prepareMailbox(user, netuid);
        bytes32 mailboxColdkey = _mailboxColdkey(user, netuid);
        mock.setStake(fromHotkey, _toSubstrate(user), netuid, amount);
        vm.prank(user);
        mock.transferStakeAndHotkey(
            mailboxColdkey, fromHotkey, mailboxColdkey, uint16(netuid), uint16(netuid), uint64(amount)
        );
    }

    /// @dev The last entry a clone's own moves may take, with the registry naming a validator it never used.
    function _blockTheNextRotation() private returns (address clone, bytes32 coldkey) {
        clone = vault.subnetClone(TOKEN1);
        coldkey = _toSubstrate(clone);
        _fillListTo(coldkey, STAKING_LIST_CAP - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
    }

    function _expectTransferAndHotkey(bytes32 cloneColdkey, bytes32 mailboxColdkey, bytes32 landing, uint256 amount)
        private
    {
        vm.expectCall(
            STAKING_PRECOMPILE,
            abi.encodeCall(
                IStaking.transferStakeAndHotkey,
                (cloneColdkey, mailboxColdkey, landing, uint16(NETUID1), uint16(NETUID1), uint64(amount))
            ),
            1
        );
    }

    function _parkAfterASweep(bytes32 hotkey, bytes32 returnHotkey) private {
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey);
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, returnHotkey, swept);
        vault.recoverStray(TOKEN1, returnHotkey);
        vault.syncBacking(TOKEN1);
    }

    function test_FirstDeposit_LiftsTheFlagForTheTransferAndSetsItBack() public {
        _sendToMailbox(alice, NETUID1, hotkey1, 10 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        assertEq(_stakingHotkeyCount(cloneColdkey), 0, "a fresh clone lists nothing");
        vm.expectCall(STAKING_PRECOMPILE, abi.encodeCall(IStaking.setRejectStakingHotkeyGrowth, (false)), 1);
        vm.expectCall(STAKING_PRECOMPILE, abi.encodeCall(IStaking.setRejectStakingHotkeyGrowth, (true)), 1);

        _wrapHotkey(alice, NETUID1, hotkey1);

        assertTrue(mock.getRejectStakingHotkeyGrowth(cloneColdkey), "the flag is back up");
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
        assertEq(_stakingHotkeyCount(cloneColdkey), 3, "the clone lists the attested set");
        assertEq(_stakingHotkeyCount(_mailboxColdkey(alice, NETUID1)), 0, "an emptied mailbox lists nothing");
    }

    function testFuzz_Deposit_LandsOnAFundedValidatorDirectly(uint256 amount) public {
        amount = bound(amount, ALPHA, 100_000 * ALPHA);
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _sendToMailbox(bob, NETUID1, hotkey2, amount);
        _expectTransferAndHotkey(_subnetColdkey(NETUID1), _mailboxColdkey(bob, NETUID1), hotkey2, amount);
        vm.expectCall(STAKING_PRECOMPILE, abi.encodeWithSelector(IStaking.setRejectStakingHotkeyGrowth.selector), 0);

        _wrapHotkey(bob, NETUID1, hotkey2);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA + amount, "the whole deposit backs the position");
    }

    function test_Deposit_OntoAnUnfundedValidator_LandsOnAListedHotkeyThenMoves() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _sendToMailbox(bob, NETUID1, hotkey1, 6 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _expectTransferAndHotkey(cloneColdkey, _mailboxColdkey(bob, NETUID1), hotkey1, 6 * ALPHA);
        vm.expectCall(
            STAKING_PRECOMPILE, abi.encodeCall(IStaking.moveStake, (hotkey1, hotkey4, NETUID1, NETUID1, 6 * ALPHA)), 1
        );

        _wrapHotkey(bob, NETUID1, hotkey4);

        assertEq(lens.totalStake(TOKEN1), 36 * ALPHA);
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the dropped validator was consolidated");
        assertEq(_getVaultStake(hotkey1, NETUID1), 12_002_400_000, "3334 bps of 36 alpha");
        assertEq(_getVaultStake(hotkey4, NETUID1), 11_998_800_000, "the new validator holds 3333 bps of 36 alpha");
    }

    function test_FirstDepositAfterAFullExit_LandsOnACrumbPinnedHotkeyThenMoves() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2, CRUMB);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(_stakingHotkeyCount(cloneColdkey), 1, "only the crumb-pinned validator stays listed");
        _sendToMailbox(bob, NETUID1, hotkey1, 6 * ALPHA);
        _expectTransferAndHotkey(cloneColdkey, _mailboxColdkey(bob, NETUID1), hotkey3, 6 * ALPHA);

        _wrapHotkey(bob, NETUID1, hotkey1);

        assertEq(lens.totalStake(TOKEN1), 6 * ALPHA);
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the landing hotkey holds nothing afterwards");
        assertEq(_getVaultStake(hotkey1, NETUID1), 3 * ALPHA, "half of the 6 alpha on each validator");
        assertEq(_getVaultStake(hotkey2, NETUID1), 3 * ALPHA);
    }

    function test_FirstDeposit_RevertedWrap_LeavesTheFlagUp() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 10e18));
        vault.wrap(NETUID1, hotkey1, type(uint256).max);

        assertTrue(mock.getRejectStakingHotkeyGrowth(cloneColdkey), "the lift reverted with the wrap");
        assertEq(_stakingHotkeyCount(cloneColdkey), 0);
    }

    function test_RotatingBackToAnEmptyListedValidatorAtTheCap_WaitsForReplacement() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2, CRUMB);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the rotated-out validator holds nothing here");
        _fillListTo(cloneColdkey, STAKING_LIST_CAP - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(3334, 3333, 3333));

        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the move onto the returning validator is skipped at the cap");

        vault.replaceClone(TOKEN1, FRESH_UID);
        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey3, NETUID1), 9_999_000_000, "the successor funds 3333 bps of 30 alpha");
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 6 * ALPHA);
        bytes32 bobColdkey = _toSubstrate(bob);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, bobColdkey, 0);

        assertEq(_getStake(hotkey1, bob, NETUID1), 6 * ALPHA, "bob's exit pays his 6 alpha");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "deposit and exit go through after replacement");
    }

    function testFuzz_DepositOntoAnUnlistedValidator_PassesOnlyBelowTheReserve(uint256 entries) public {
        entries = bound(entries, 1, STAKING_LIST_CAP - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillListTo(_subnetColdkey(NETUID1), entries);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4), _weights(5000, 5000));
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);

        if (entries <= STAKING_LIST_CAP - 2) {
            vm.prank(bob);
            vault.wrap(NETUID1, hotkey4, 0);
            assertEq(_getVaultStake(hotkey4, NETUID1), 18 * ALPHA, "half of 36 alpha on the new validator");
        } else {
            vm.prank(bob);
            vm.expectRevert(IAlphaVaultAbi.StakingListFull.selector);
            vault.wrap(NETUID1, hotkey4, 0);
        }
    }

    function test_FullExit_EmptiesTheList_AndTheNextDepositStillLands() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(_stakingHotkeyCount(cloneColdkey), 0, "a drained clone lists nothing");

        _depositAndWrap(bob, NETUID1, 5 * ALPHA);

        assertEq(lens.totalStake(TOKEN1), 5 * ALPHA);
        assertTrue(mock.getRejectStakingHotkeyGrowth(cloneColdkey));
    }

    function test_RetainedCrumb_AfterRotation_KeepsTheEntry() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2, CRUMB);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the rotated-out validator was consolidated");
        assertEq(_stakingHotkeyCount(cloneColdkey), 3, "the crumb keeps the rotated-out validator listed");
    }

    function test_Rotation_KeepsOneEntryFreeForParking_AndRecoveryParks() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2, CRUMB);
        _fillListTo(cloneColdkey, STAKING_LIST_CAP - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the alignment onto the new validator waits");
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        vm.prank(bob);
        vm.expectRevert(IAlphaVaultAbi.StakingListFull.selector);
        vault.wrap(NETUID1, hotkey4, 0);

        _parkAfterASweep(hotkey1, hotkey3);
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "parking took the reserved entry");
        assertTrue(vault.awaitingAttestation(TOKEN1));
        _setValidators(NETUID1, _hotkeys(hotkey3, hotkey4), _weights(5000, 5000));

        vault.rebalance(NETUID1);

        assertFalse(vault.awaitingAttestation(TOKEN1), "the release fits once the emptied entries left");
        assertEq(_getVaultStake(hotkey3, NETUID1), 15 * ALPHA);
        assertEq(_getVaultStake(hotkey4, NETUID1), 15 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
    }

    function testFuzz_RecoveryParks_AtAnyListLength(uint256 entries) public {
        entries = bound(entries, 1, STAKING_LIST_CAP - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillListTo(_subnetColdkey(NETUID1), entries);

        _parkAfterASweep(hotkey1, hotkey5);

        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "parking always has its entry");
    }

    function _secondShortfallWithParkingListedButUnfunded(uint256 fillTo) private returns (bytes32 cloneColdkey) {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2, CRUMB);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        vault.rebalance(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID1, CRUMB);
        _fillListTo(cloneColdkey, fillTo);

        _parkAfterASweep(hotkey1, hotkey5);
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "parked");
        assertEq(_stakingHotkeyCount(cloneColdkey), fillTo + 1, "parking took one entry");
        _strangerTransfer(vault.parkingHotkey(), cloneColdkey, NETUID2, CRUMB);

        _setValidators(NETUID1, _hotkeys(hotkey3), _weights(BPS_BASE));
        vault.rebalance(NETUID1);
        assertEq(_parkedStake(NETUID1), 0, "released onto the crumb-funded validator");
        assertEq(_getVaultStake(hotkey3, NETUID1), 30_002_000_000, "30 alpha joined the 0.002-alpha crumb");
        assertEq(_stakingHotkeyCount(cloneColdkey), fillTo + 1, "the crumb keeps parking listed");

        uint256 lost = _sweepDuringCrash(NETUID1, hotkey3);
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, hotkey4, lost);
    }

    function test_AtTheCap_RecoveryParksOntoAListedButUnfundedParkingHotkey() public {
        bytes32 cloneColdkey = _secondShortfallWithParkingListedButUnfunded(STAKING_LIST_CAP - 2);
        assertEq(_stakingHotkeyCount(cloneColdkey), STAKING_LIST_CAP);

        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);

        (uint256 shortSince,) = vault.recovery(TOKEN1);
        assertEq(_parkedStake(NETUID1), 30_002_000_000, "the second shortfall parks at the cap");
        assertEq(shortSince, 0, "recovery completes");
        vault.replaceClone(TOKEN1, FRESH_UID);
        assertEq(lens.totalStake(TOKEN1), 30_002_000_000, "the successor backs the position");
    }

    function testFuzz_SecondShortfall_Parks_AtAnyListLength(uint256 fillTo) public {
        fillTo = bound(fillTo, 2, STAKING_LIST_CAP - 2);
        _secondShortfallWithParkingListedButUnfunded(fillTo);

        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(_parkedStake(NETUID1), 30_002_000_000, "the second shortfall parks");
    }

    function test_AtTheReserve_ConsolidationReturnsToTheDrainedPinnedHome_AndTheExitPays() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey1, cloneColdkey, NETUID2, CRUMB);
        _fillListTo(cloneColdkey, STAKING_LIST_CAP - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the dropped validator was consolidated");
        assertEq(lens.totalStake(TOKEN1), 15 * ALPHA, "the exit paid out");
        assertEq(_getStake(hotkey1, alice, NETUID1), 15 * ALPHA, "half of 30 alpha from the consolidated home");
        assertEq(_getVaultStake(hotkey1, NETUID1), 7.5e9);
        assertEq(_getVaultStake(hotkey2, NETUID1), 7.5e9);
    }

    function testFuzz_ConsolidationReturnsToTheDrainedHome_AtAnyListLength(uint256 entries, bool pinHome) public {
        entries = bound(entries, 3, STAKING_LIST_CAP - 1);
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        if (pinHome) _strangerTransfer(hotkey1, cloneColdkey, NETUID2, CRUMB);
        _fillListTo(cloneColdkey, entries);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the dropped validator was consolidated");
        assertEq(_getVaultStake(hotkey1, NETUID1), 15 * ALPHA);
        assertEq(_getVaultStake(hotkey2, NETUID1), 15 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
    }

    /// @dev Crumbs keep the dropped validators listed, so consolidation frees no entry on its way out.
    function test_FullRotationAtTheReserve_AlphaExitWaitsForReplacement_TaoExitDoesNot() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey1, cloneColdkey, NETUID2, CRUMB);
        _strangerTransfer(hotkey2, cloneColdkey, NETUID2, CRUMB);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2, CRUMB);
        _fillListTo(cloneColdkey, STAKING_LIST_CAP - 1);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey5), _weights(5000, 5000));
        bytes32 aliceColdkey = _toSubstrate(alice);

        vm.prank(alice);
        vm.expectRevert(IAlphaVaultAbi.StakingListFull.selector);
        vault.unwrap(TOKEN1, shares / 2, aliceColdkey, 0);
        uint256 taoBefore = alice.balance;
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
        assertEq(alice.balance - taoBefore, 0.375e18, "the TAO exit sells 7.5 alpha at 0.05 TAO without waiting");
        assertEq(vault.balanceOf(alice, TOKEN1), 22.5e18, "a quarter of the 3e19 shares burned");

        vault.replaceClone(TOKEN1, FRESH_UID);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, aliceColdkey, 0);

        assertEq(_getStake(hotkey4, alice, NETUID1), 15 * ALPHA, "the alpha exit paid from the successor");
        assertEq(_getStake(hotkey5, alice, NETUID1), 0);
    }

    function test_PartialExit_SkipsAnAlignmentMoveTheListRefuses() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2, CRUMB);
        _fillListTo(cloneColdkey, STAKING_LIST_CAP - 1);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey1, hotkey2), _weights(3334, 3333, 3333));

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the dropped validator was consolidated onto a funded one");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the unlisted validator waits for a replacement");
        assertEq(_getStake(hotkey1, alice, NETUID1), 15 * ALPHA, "the exit paid half of 30 alpha");
        assertEq(_getVaultStake(hotkey1, NETUID1), 5_001_000_000, "20.001 alpha less the 15 paid");
        assertEq(_getVaultStake(hotkey2, NETUID1), 9_999_000_000, "the refused alignment leaves hotkey2 as it was");
        assertEq(lens.totalStake(TOKEN1), 15 * ALPHA);
    }

    function test_RevertWhen_AnOwnMoveWouldPassTheListCap_UntilTheCloneIsReplaced() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        (address clone, bytes32 cloneColdkey) = _blockTheNextRotation();
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);

        vm.prank(bob);
        vm.expectRevert(IAlphaVaultAbi.StakingListFull.selector);
        vault.wrap(NETUID1, hotkey4, 0);

        address successor = _cloneCandidate(TOKEN1, FRESH_UID);
        vm.expectEmit(true, true, true, true, address(vault));
        emit SubnetCloneReplaced(TOKEN1, clone, successor);
        vault.replaceClone(TOKEN1, FRESH_UID);
        _wrapHotkey(bob, NETUID1, hotkey4);

        assertEq(vault.subnetClone(TOKEN1), successor, "the token moved to the announced clone");
        assertEq(lens.totalStake(TOKEN1), 36 * ALPHA, "the deposit lands once the list has room");
        assertEq(_getVaultStake(hotkey4, NETUID1), 11_998_800_000, "3333 bps of 36 alpha on the new validator");
        assertEq(_stakingHotkeyCount(_toSubstrate(successor)), 3, "the successor lists the attested set");
        assertEq(_stakingHotkeyCount(cloneColdkey), STAKING_LIST_CAP - 1 - 3, "the crumbs stay on the old clone");
    }

    function test_ReplaceClone_KeepsTheTokenSharesAndTaoClaims() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, TAO);
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, 1, "");
        assertEq(vault.taoLiability(TOKEN1), TAO, "the donation is reserved whole");
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 999_999_999e9, "the donation less the index's floor rounding");
        _blockTheNextRotation();

        vault.replaceClone(TOKEN1, FRESH_UID);

        address successor = vault.subnetClone(TOKEN1);
        bytes32 successorColdkey = _toSubstrate(successor);
        assertEq(vault.currentTokenId(NETUID1), TOKEN1, "the token id does not change");
        assertEq(vault.balanceOf(alice, TOKEN1), shares - 1);
        assertEq(vault.totalSupply(TOKEN1), shares);
        assertEq(successor.balance, TAO, "the TAO moved with the position");
        assertEq(clone.balance, 0);
        assertEq(vault.taoLiability(TOKEN1), TAO, "moving TAO credits nothing twice");
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 999_999_999e9);
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the backing moved under the same hotkeys");
        assertTrue(mock.getRejectStakingHotkeyGrowth(successorColdkey), "the successor refuses growth");
        (, bytes32 owner) = mock.getHotkeyOwner(successorColdkey);
        assertTrue(owner != _toSubstrate(address(vault)), "a fresh owner claims the successor");
        assertEq(owner, _toSubstrate(vault.cloneFactory().cloneOwnerOf(successorColdkey)), "the factory's owner");
        assertEq(_stakingHotkeyCount(_toSubstrate(address(vault))), 1, "the vault still lists parking only");

        assertEq(_claimQuotedAmount(alice, TOKEN1), 999_999_999e9, "the claim pays from the successor");
        _depositAndWrap(bob, NETUID1, 6 * ALPHA);
        bytes32 aliceColdkey = _toSubstrate(alice);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, aliceColdkey, 0);
        vault.rebalance(NETUID1);
        assertEq(_getStake(hotkey2, alice, NETUID1), 15 * ALPHA, "the exit pays half of 30 alpha");
        assertEq(_getVaultStake(hotkey4, NETUID1), 6_999_300_000, "the rotation lands 3333 bps of 21 alpha");
        assertEq(lens.totalStake(TOKEN1), 21 * ALPHA, "deposit and exit went through on the successor");
    }

    function test_ReplaceClone_MovesASingleRaoOfTao() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        (address clone,) = _blockTheNextRotation();
        _donateToClone(clone, 1e9);

        vault.replaceClone(TOKEN1, FRESH_UID);

        assertEq(clone.balance, 0, "the old clone keeps no TAO");
        assertEq(vault.subnetClone(TOKEN1).balance, 1e9, "the successor holds the single RAO");
    }

    function test_ReplaceClone_WhileParked_LetsTheNextAttestationRelease() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillListTo(_subnetColdkey(NETUID1), STAKING_LIST_CAP - 1);
        _parkAfterASweep(hotkey1, hotkey4);
        assertTrue(vault.awaitingAttestation(TOKEN1), "the position rests on parking");
        _setValidators(NETUID1, _hotkeys(hotkey5, hotkey2), _weights(5000, 5000));

        vm.expectRevert(IAlphaVaultAbi.StakingListFull.selector);
        vault.rebalance(NETUID1);
        vault.replaceClone(TOKEN1, FRESH_UID);
        vault.rebalance(NETUID1);

        assertFalse(vault.awaitingAttestation(TOKEN1), "the release landed on the successor");
        assertEq(_getVaultStake(hotkey5, NETUID1), 15 * ALPHA);
        assertEq(_getVaultStake(hotkey2, NETUID1), 15 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
    }

    function test_ReplaceClone_LeavesSubFloorPilesBehind() public {
        _depositAndWrap(alice, NETUID1, 60 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 30 * ALPHA;
        amounts[1] = 20_000_000;
        amounts[2] = 30 * ALPHA;
        _plantVaultLayout(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), amounts);
        _blockTheNextRotation();

        vault.replaceClone(TOKEN1, FRESH_UID);

        assertEq(_getStakeForColdkey(hotkey2, _toSubstrate(clone), NETUID1), 20_000_000, "the 0.001-TAO pile stays");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0);
        assertEq(vault.recordedSlots(TOKEN1)[1].tracked, 0, "the record follows what arrived");
        assertEq(lens.totalStake(TOKEN1), 60 * ALPHA);
        _depositAndWrap(bob, NETUID1, 6 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 66 * ALPHA, "deposits continue on the successor");
    }

    function testFuzz_ReplaceClone_LosesOnlyTheChainRoundingOfEachMove(uint256 deposit, uint256 loss) public {
        deposit = bound(deposit, ALPHA, 1_000_000 * ALPHA);
        loss = bound(loss, 0, 2);
        _depositAndWrap(alice, NETUID1, deposit);
        _blockTheNextRotation();
        mock.setTransferStakeRoundingLoss(loss);

        vault.replaceClone(TOKEN1, FRESH_UID);

        assertEq(vault.totalSupply(TOKEN1), deposit * 1e9, "shares are untouched");
        assertEq(lens.totalStake(TOKEN1), deposit - 3 * loss, "each of the three moved piles loses the rounding");
    }

    function test_ReplaceClone_ASecondReplacementCarriesThePositionToAThirdClone() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _blockTheNextRotation();
        vault.replaceClone(TOKEN1, FRESH_UID);
        address second = vault.subnetClone(TOKEN1);
        vault.rebalance(NETUID1);
        _fillListTo(_toSubstrate(second), STAKING_LIST_CAP - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey5), _weights(3334, 3333, 3333));

        vault.replaceClone(TOKEN1, keccak256("another-uid"));
        vault.rebalance(NETUID1);

        assertTrue(vault.subnetClone(TOKEN1) != second, "a third clone took over");
        assertEq(_getVaultStake(hotkey5, NETUID1), 9_999_000_000, "3333 bps of 30 alpha on the newest validator");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
    }

    function test_CreateMailbox_AfterReplacement_ReturnsTheSuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _blockTheNextRotation();
        vault.replaceClone(TOKEN1, FRESH_UID);

        vm.prank(bob);
        (, address clone) = vault.createMailbox(NETUID1, keccak256("bob-uid"));

        assertEq(clone, vault.subnetClone(TOKEN1));
    }

    function test_ReplaceClone_RetriesWithAFreshUidPastAContaminatedCandidate() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _blockTheNextRotation();
        address candidate = _cloneCandidate(TOKEN1, FRESH_UID);
        mock.setHotkeyOwner(_toSubstrate(candidate), _toSubstrate(bob));

        vm.expectRevert(abi.encodeWithSelector(IAlphaVaultAbi.CloneContaminated.selector, candidate));
        vault.replaceClone(TOKEN1, FRESH_UID);

        vault.replaceClone(TOKEN1, keccak256("retry-uid"));
        assertEq(vault.subnetClone(TOKEN1), _cloneCandidate(TOKEN1, keccak256("retry-uid")), "the retry uid's clone");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the position moved whole");
    }

    function test_ReplacementOpensAtHalfTheCap() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _fillListTo(cloneColdkey, REPLACEMENT_OPENS_AT - 1);
        vm.expectRevert(StakingListHasRoom.selector);
        vault.replaceClone(TOKEN1, FRESH_UID);

        _fillListTo(cloneColdkey, REPLACEMENT_OPENS_AT);
        vault.replaceClone(TOKEN1, FRESH_UID);

        assertEq(_stakingHotkeyCount(_subnetColdkey(NETUID1)), 3, "the successor lists the attested set");
    }

    function testFuzz_Replacement_OpensOnlyFromTheThreshold(uint256 entries) public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        entries = bound(entries, 3, STAKING_LIST_CAP - 1);
        _fillListTo(_subnetColdkey(NETUID1), entries);

        if (entries < REPLACEMENT_OPENS_AT) {
            vm.expectRevert(StakingListHasRoom.selector);
            vault.replaceClone(TOKEN1, FRESH_UID);
        } else {
            vault.replaceClone(TOKEN1, FRESH_UID);
            assertEq(_stakingHotkeyCount(_subnetColdkey(NETUID1)), 3, "the successor lists the attested set");
        }
    }

    function test_Replacement_NeedsNoValidatorSet() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillListTo(_subnetColdkey(NETUID1), REPLACEMENT_OPENS_AT);
        registry.setRaw(NETUID1, new bytes32[](0), new uint16[](0));

        vault.replaceClone(TOKEN1, FRESH_UID);

        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the position moved without a registry read");
    }

    function test_RevertWhen_ReplacingAnUnpreparedToken() public {
        vm.expectRevert(SubnetCloneNotPrepared.selector);
        vault.replaceClone(TOKEN1, FRESH_UID);
    }

    function test_RevertWhen_ReplacingWhileAShortfallIsOnFile() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillListTo(_subnetColdkey(NETUID1), STAKING_LIST_CAP - 1);
        _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));

        vm.expectRevert(ShortfallOnFile.selector);
        vault.replaceClone(TOKEN1, FRESH_UID);
    }

    function test_RevertWhen_ReplacingWithTransfersDisabled() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _blockTheNextRotation();
        _setTransfersEnabled(NETUID1, false);

        vm.expectRevert(abi.encodeWithSelector(AlphaTransfersDisabled.selector, uint16(NETUID1)));
        vault.replaceClone(TOKEN1, FRESH_UID);
    }

    function test_RevertWhen_ReplacingADissolvingOrDissolvedToken() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _blockTheNextRotation();
        _simulateDissolutionStarted(NETUID1);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.replaceClone(TOKEN1, FRESH_UID);

        _simulateDissolutionCompleted(NETUID1);
        vm.expectRevert(SubnetDissolved.selector);
        vault.replaceClone(TOKEN1, FRESH_UID);
    }
}
