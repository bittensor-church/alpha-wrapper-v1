// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MAX_STAKING_HOTKEYS } from "src/interfaces/IValidatorRegistry.sol";
import {
    AlphaTransfersDisabled,
    ShortfallOnFile,
    SlippageExceeded,
    StakingListFull,
    StakingListHasRoom,
    SubnetCloneNotPrepared,
    SubnetDissolved,
    SubnetInDissolutionBlackoutPeriod
} from "src/VaultErrors.sol";

contract DepositLandingTest is AlphaVaultTestBase {
    bytes32 private constant FRESH_UID = keccak256("fresh-clone-uid");
    address private stranger = makeAddr("stranger");
    MockStaking private mock;

    function setUp() public override {
        super.setUp();
        mock = MockStaking(STAKING_PRECOMPILE);
    }

    function _sendToMailbox(address user, uint256 netuid, bytes32 fromHotkey, uint256 amount) private {
        _prepareMailbox(user, netuid);
        bytes32 mailboxColdkey = _mailboxColdkey(user, netuid);
        mock.setStake(fromHotkey, _toSubstrate(user), netuid, amount);
        vm.prank(user);
        mock.transferStakeAndHotkey(
            mailboxColdkey, fromHotkey, mailboxColdkey, uint16(netuid), uint16(netuid), uint64(amount)
        );
    }

    function _strangerTransfer(bytes32 hotkey, bytes32 coldkey, uint256 netuid) private {
        mock.setStake(hotkey, _toSubstrate(stranger), netuid, CRUMB);
        vm.prank(stranger);
        mock.transferStake(coldkey, hotkey, netuid, netuid, CRUMB);
    }

    /// @dev The last entry a clone's own moves may take, with the registry naming a validator it never used.
    function _blockTheNextRotation() private returns (address clone, bytes32 coldkey) {
        clone = vault.subnetClone(TOKEN1);
        coldkey = _toSubstrate(clone);
        _fillListTo(coldkey, MAX_STAKING_HOTKEYS - 1);
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
        assertGt(_getVaultStake(hotkey4, NETUID1), 0, "the new validator holds its weight");
    }

    function test_FirstDepositAfterAFullExit_LandsOnACrumbPinnedKeyThenMoves() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        vault.rebalance(NETUID1);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(_stakingHotkeyCount(cloneColdkey), 1, "only the crumb-pinned validator stays listed");
        _sendToMailbox(bob, NETUID1, hotkey1, 6 * ALPHA);
        _expectTransferAndHotkey(cloneColdkey, _mailboxColdkey(bob, NETUID1), hotkey3, 6 * ALPHA);

        _wrapHotkey(bob, NETUID1, hotkey1);

        assertEq(lens.totalStake(TOKEN1), 6 * ALPHA);
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the landing key holds nothing afterwards");
        assertGt(_getVaultStake(hotkey1, NETUID1), 0);
    }

    function test_FirstDeposit_RevertedWrap_LeavesTheFlagUp() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);

        vm.prank(alice);
        vm.expectPartialRevert(SlippageExceeded.selector);
        vault.wrap(NETUID1, hotkey1, type(uint256).max);

        assertTrue(mock.getRejectStakingHotkeyGrowth(cloneColdkey), "the lift reverted with the wrap");
        assertEq(_stakingHotkeyCount(cloneColdkey), 0);
    }

    function testFuzz_RotatingBackToAListedValidator_AtAnyListPosition(uint256 position) public {
        position = bound(position, 0, MAX_STAKING_HOTKEYS - 4);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _fillListTo(cloneColdkey, 2 + position);
        mock.setStake(hotkey3, cloneColdkey, NETUID2, CRUMB);
        _fillListTo(cloneColdkey, MAX_STAKING_HOTKEYS - 1);
        (bytes32[] memory page,) = mock.getStakingHotkeys(cloneColdkey, uint64(2 + position), 1);
        assertEq(page[0], hotkey3, "the listed validator sits at the fuzzed position");

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(3334, 3333, 3333));
        vault.rebalance(NETUID1);

        assertGt(_getVaultStake(hotkey3, NETUID1), 0, "a listed validator takes stake wherever it is listed");
    }

    function test_RotatingBackToAListedValidatorAtTheCap_Works() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the rotated-out validator holds nothing here");
        _fillListTo(cloneColdkey, MAX_STAKING_HOTKEYS - 1);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(3334, 3333, 3333));
        vault.rebalance(NETUID1);
        assertGt(_getVaultStake(hotkey3, NETUID1), 0, "a listed validator takes stake at the cap");
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 6 * ALPHA);
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);

        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 * ALPHA, 2, "deposit and exit went through at the cap");
    }

    function testFuzz_DepositOntoAnUnlistedValidator_PassesOnlyBelowTheReserve(uint256 entries) public {
        entries = bound(entries, 1, MAX_STAKING_HOTKEYS - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillListTo(_subnetColdkey(NETUID1), entries);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey4), _weights(5000, 5000));
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);

        if (entries + 2 > MAX_STAKING_HOTKEYS) vm.expectRevert(StakingListFull.selector);
        vm.prank(bob);
        vault.wrap(NETUID1, hotkey4, 0);

        if (entries + 2 <= MAX_STAKING_HOTKEYS) {
            assertGt(_getVaultStake(hotkey4, NETUID1), 0, "the deposit landed on the new validator");
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

    function test_StrangerCannotAddHotkeysToAClone_ButADepositStillLands() public {
        address mailbox = _prepareMailbox(alice, NETUID1);
        bytes32 strangerHotkey = keccak256("stranger hotkey");
        mock.setHotkeyOwned(strangerHotkey, true);
        bytes32[2] memory targets = [_toSubstrate(mailbox), _subnetColdkey(NETUID1)];
        for (uint256 i; i < targets.length; ++i) {
            mock.setStake(strangerHotkey, _toSubstrate(stranger), NETUID2, CRUMB);
            vm.prank(stranger);
            _expectChainRefusal();
            mock.transferStake(targets[i], strangerHotkey, NETUID2, NETUID2, CRUMB);
        }
        assertEq(_stakingHotkeyCount(targets[0]), 1, "the mailbox lists only its own hotkey");
        assertEq(_stakingHotkeyCount(targets[1]), 0, "the clone lists nothing");

        _sendToMailbox(alice, NETUID1, hotkey1, 10 * ALPHA);
        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
    }

    function test_RetainedCrumb_AfterRotation_KeepsTheEntry() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the rotated-out validator was consolidated");
        assertEq(_stakingHotkeyCount(cloneColdkey), 3, "the crumb keeps the rotated-out validator listed");
    }

    function test_Rotation_KeepsOneEntryFreeForParking_AndRecoveryParks() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2);
        _fillListTo(cloneColdkey, MAX_STAKING_HOTKEYS - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the alignment onto the new validator waits");
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);
        vm.prank(bob);
        vm.expectRevert(StakingListFull.selector);
        vault.wrap(NETUID1, hotkey4, 0);

        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey5);
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, hotkey5);
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "parking took the reserved entry");
        vault.syncBacking(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1));
        _setValidators(NETUID1, _hotkeys(hotkey3, hotkey4), _weights(5000, 5000));

        vault.rebalance(NETUID1);

        assertFalse(vault.awaitingAttestation(TOKEN1), "the release fits once the emptied entries left");
        assertGt(_getVaultStake(hotkey4, NETUID1), 0);
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 * ALPHA, 2);
    }

    function testFuzz_RecoveryParks_AtAnyListLength(uint256 entries) public {
        entries = bound(entries, 1, MAX_STAKING_HOTKEYS - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillListTo(_subnetColdkey(NETUID1), entries);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey5);
        vault.syncBacking(TOKEN1);

        vault.recoverStray(TOKEN1, hotkey5);

        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "parking always has its entry");
    }

    /// @dev Crumbs keep the dropped validators listed, so consolidation frees no entry on its way out.
    function test_FullRotationAtTheReserve_AlphaExitWaitsForReplacement_TaoExitDoesNot() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey1, cloneColdkey, NETUID2);
        _strangerTransfer(hotkey2, cloneColdkey, NETUID2);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2);
        _fillListTo(cloneColdkey, MAX_STAKING_HOTKEYS - 1);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey5), _weights(5000, 5000));

        vm.prank(alice);
        vm.expectRevert(StakingListFull.selector);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        vm.prank(alice);
        vault.unwrapForTao(TOKEN1, shares / 4, 0);
        assertEq(vault.balanceOf(alice, TOKEN1), shares - shares / 4, "the TAO exit does not wait");

        vault.replaceClone(TOKEN1, FRESH_UID);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        assertGt(_getStake(hotkey4, alice, NETUID1) + _getStake(hotkey5, alice, NETUID1), 0, "the alpha exit paid");
    }

    function test_PartialExit_SkipsAnAlignmentMoveTheListRefuses() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2);
        _fillListTo(cloneColdkey, MAX_STAKING_HOTKEYS - 1);
        _setValidators(NETUID1, _hotkeys(hotkey4, hotkey1, hotkey2), _weights(3334, 3333, 3333));

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the dropped validator was consolidated onto a funded one");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0, "the unlisted validator waits for a replacement");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 15 * ALPHA, 2, "the exit paid out");
    }

    function test_RevertWhen_AnOwnMoveWouldPassTheListCap_UntilTheCloneIsReplaced() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        (address clone, bytes32 cloneColdkey) = _blockTheNextRotation();
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);

        vm.prank(bob);
        vm.expectRevert(StakingListFull.selector);
        vault.wrap(NETUID1, hotkey4, 0);

        vm.expectEmit(true, true, false, false, address(vault));
        emit SubnetCloneReplaced(TOKEN1, clone, address(0));
        vault.replaceClone(TOKEN1, FRESH_UID);
        address successor = vault.subnetClone(TOKEN1);
        _wrapHotkey(bob, NETUID1, hotkey4);

        assertTrue(successor != clone, "the token has a fresh clone");
        assertEq(lens.totalStake(TOKEN1), 36 * ALPHA, "the deposit lands once the list has room");
        assertGt(_getVaultStake(hotkey4, NETUID1), 0);
        assertEq(_stakingHotkeyCount(_toSubstrate(successor)), 3, "the successor lists the attested set");
        assertEq(_stakingHotkeyCount(cloneColdkey), MAX_STAKING_HOTKEYS - 1 - 3, "the crumbs stay on the old clone");
    }

    function test_ReplaceClone_KeepsTheTokenSharesAndTaoClaims() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);
        _donateToClone(clone, TAO);
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, TOKEN1, 1, "");
        uint256 liabilityBefore = vault.taoLiability(TOKEN1);
        uint256 claimBefore = lens.claimableTaoOf(alice, TOKEN1);
        assertGt(claimBefore, 0, "the donation is owed before the replacement");
        _blockTheNextRotation();

        vault.replaceClone(TOKEN1, FRESH_UID);

        address successor = vault.subnetClone(TOKEN1);
        assertEq(vault.currentTokenId(NETUID1), TOKEN1, "the token id does not change");
        assertEq(vault.balanceOf(alice, TOKEN1), shares - 1);
        assertEq(vault.totalSupply(TOKEN1), shares);
        assertEq(successor.balance, TAO, "the TAO moved with the position");
        assertEq(clone.balance, 0);
        assertEq(vault.taoLiability(TOKEN1), liabilityBefore, "moving TAO credits nothing twice");
        assertEq(lens.claimableTaoOf(alice, TOKEN1), claimBefore);
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 * ALPHA, 2, "the backing moved under the same hotkeys");
        assertTrue(mock.getRejectStakingHotkeyGrowth(_toSubstrate(successor)), "the successor refuses growth");
        (, bytes32 owner) = mock.getHotkeyOwner(_toSubstrate(successor));
        assertTrue(owner != _toSubstrate(address(vault)), "a fresh owner claims the successor");
        assertEq(_stakingHotkeyCount(_toSubstrate(address(vault))), 1, "the vault still lists parking only");

        _claimQuotedAmount(alice, TOKEN1);
        _depositAndWrap(bob, NETUID1, 6 * ALPHA);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        vault.rebalance(NETUID1);
        assertGt(_getVaultStake(hotkey4, NETUID1), 0, "the rotation lands on the successor");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 21 * ALPHA, 4, "deposit and exit went through on the successor");
    }

    function test_ReplaceClone_LeavesTaoBelowTheExistentialDepositBehind() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        (address clone,) = _blockTheNextRotation();
        _donateToClone(clone, EXISTENTIAL_DEPOSIT - 1e9);

        vault.replaceClone(TOKEN1, FRESH_UID);

        assertEq(clone.balance, EXISTENTIAL_DEPOSIT - 1e9, "TAO the successor could not show stays behind");
        assertEq(vault.subnetClone(TOKEN1).balance, 0);
        assertEq(vault.taoLiability(TOKEN1), 0);
    }

    function test_ReplaceClone_WhileParked_LetsTheNextAttestationRelease() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _fillListTo(cloneColdkey, MAX_STAKING_HOTKEYS - 1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        vault.syncBacking(TOKEN1);
        vault.recoverStray(TOKEN1, hotkey4);
        vault.syncBacking(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1), "the position rests on parking");
        _setValidators(NETUID1, _hotkeys(hotkey5, hotkey2), _weights(5000, 5000));

        vm.expectRevert(StakingListFull.selector);
        vault.rebalance(NETUID1);
        vault.replaceClone(TOKEN1, FRESH_UID);
        vault.rebalance(NETUID1);

        assertFalse(vault.awaitingAttestation(TOKEN1), "the release landed on the successor");
        assertGt(_getVaultStake(hotkey5, NETUID1), 0);
        assertGt(_getVaultStake(hotkey2, NETUID1), 0);
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 * ALPHA, 4);
    }

    function test_ReplaceClone_LeavesSubFloorPilesBehind() public {
        _depositAndWrap(alice, NETUID1, 60 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 30 * ALPHA;
        amounts[1] = 1_000_000;
        amounts[2] = 30 * ALPHA;
        _plantVaultLayout(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), amounts);
        _blockTheNextRotation();

        vault.replaceClone(TOKEN1, FRESH_UID);

        assertEq(_getStakeForColdkey(hotkey2, _toSubstrate(clone), NETUID1), 1_000_000, "the dust stays behind");
        assertEq(_getVaultStake(hotkey2, NETUID1), 0);
        assertEq(vault.recordedSlots(TOKEN1)[1].tracked, 0, "the record follows what arrived");
        assertApproxEqAbs(lens.totalStake(TOKEN1), 60 * ALPHA, 2);
        _depositAndWrap(bob, NETUID1, 6 * ALPHA);
        assertApproxEqAbs(lens.totalStake(TOKEN1), 66 * ALPHA, 4, "deposits continue on the successor");
    }

    function testFuzz_ReplaceClone_PreservesBackingWithinRounding(uint256 deposit, uint256 loss) public {
        deposit = bound(deposit, ALPHA, 1_000_000 * ALPHA);
        loss = bound(loss, 0, 2);
        uint256 shares = _depositAndWrap(alice, NETUID1, deposit);
        uint256 before = lens.totalStake(TOKEN1);
        _blockTheNextRotation();
        mock.setTransferStakeRoundingLoss(loss);

        vault.replaceClone(TOKEN1, FRESH_UID);

        assertEq(vault.totalSupply(TOKEN1), shares, "shares are untouched");
        assertLe(lens.totalStake(TOKEN1), before);
        assertGe(lens.totalStake(TOKEN1) + 3 * loss, before, "each moved pile loses at most the chain rounding");
    }

    function test_ReplaceClone_Twice() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _blockTheNextRotation();
        vault.replaceClone(TOKEN1, FRESH_UID);
        address second = vault.subnetClone(TOKEN1);
        vault.rebalance(NETUID1);
        _fillListTo(_toSubstrate(second), MAX_STAKING_HOTKEYS - 1);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey5), _weights(3334, 3333, 3333));

        vault.replaceClone(TOKEN1, keccak256("another-uid"));
        vault.rebalance(NETUID1);

        assertTrue(vault.subnetClone(TOKEN1) != second, "a third clone took over");
        assertGt(_getVaultStake(hotkey5, NETUID1), 0);
        assertApproxEqAbs(lens.totalStake(TOKEN1), 30 * ALPHA, 4);
    }

    function test_CreateMailbox_AfterReplacement_ReturnsTheSuccessor() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _blockTheNextRotation();
        vault.replaceClone(TOKEN1, FRESH_UID);

        vm.prank(bob);
        (, address clone) = vault.createMailbox(NETUID1, keccak256("bob-uid"));

        assertEq(clone, vault.subnetClone(TOKEN1));
    }

    function test_RevertWhen_SuccessorCandidateIsContaminated() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _blockTheNextRotation();
        address candidate = _cloneCandidate(TOKEN1, FRESH_UID);
        mock.setHotkeyOwner(_toSubstrate(candidate), _toSubstrate(bob));

        vm.expectRevert(abi.encodeWithSelector(IAlphaVaultAbi.CloneContaminated.selector, candidate));
        vault.replaceClone(TOKEN1, FRESH_UID);

        vault.replaceClone(TOKEN1, keccak256("retry-uid"));
        assertEq(vault.subnetClone(TOKEN1), _cloneCandidate(TOKEN1, keccak256("retry-uid")));
    }

    function test_RevertWhen_ReplacingACloneWithRoom() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        vm.expectRevert(StakingListHasRoom.selector);
        vault.replaceClone(TOKEN1, FRESH_UID);
    }

    function test_ReplacementOpensOnceTheListIsWithinOneSetOfTheCap() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _fillListTo(cloneColdkey, MAX_STAKING_HOTKEYS - 3 - 1);
        vm.expectRevert(StakingListHasRoom.selector);
        vault.replaceClone(TOKEN1, FRESH_UID);

        _fillListTo(cloneColdkey, MAX_STAKING_HOTKEYS - 3);
        vault.replaceClone(TOKEN1, FRESH_UID);

        assertEq(_stakingHotkeyCount(_subnetColdkey(NETUID1)), 3, "the successor lists the attested set");
    }

    function test_RevertWhen_ReplacingAnUnpreparedToken() public {
        vm.expectRevert(SubnetCloneNotPrepared.selector);
        vault.replaceClone(TOKEN1, FRESH_UID);
    }

    function test_RevertWhen_ReplacingWhileAShortfallIsOnFile() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _fillListTo(_subnetColdkey(NETUID1), MAX_STAKING_HOTKEYS - 1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey5);
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
