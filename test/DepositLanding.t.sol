// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { IStaking, STAKING_PRECOMPILE, MAX_STAKING_HOTKEYS } from "src/interfaces/IStaking.sol";
import { MismatchedArrays, NothingToRecover, StakingListFull, ZeroAmount } from "src/VaultErrors.sol";

contract DepositLandingTest is AlphaVaultTestBase {
    /// @dev 0.002 alpha, worth the mock's 0.0001 TAO transfer minimum at 0.05 TAO per alpha.
    uint256 private constant CRUMB = 2_000_000;
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

    function _plantCrumbsOnOtherSubnet(bytes32 coldkey, uint256 count) private returns (bytes32 first) {
        for (uint256 i; i < count; ++i) {
            bytes32 hotkey = keccak256(abi.encode("crumb", i));
            if (i == 0) first = hotkey;
            mock.setHotkeyOwned(hotkey, true);
            mock.setStake(hotkey, coldkey, NETUID2, CRUMB);
        }
    }

    function _netuids(uint256 netuid) private pure returns (uint16[] memory arr) {
        arr = new uint16[](1);
        arr[0] = uint16(netuid);
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

    function test_RetainedCrumb_AfterRotation_IsSoldToTheCaller() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));
        vault.rebalance(NETUID1);
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "the rotated-out validator was consolidated");
        assertEq(_stakingHotkeyCount(cloneColdkey), 3, "the crumb keeps the rotated-out validator listed");

        uint256 bobBefore = bob.balance;
        vm.expectEmit(true, true, true, true, address(vault));
        emit OtherSubnetStakeSold(TOKEN1, uint16(NETUID2), hotkey3, CRUMB, 100_000 * 1e9);
        vm.prank(bob);
        vault.sellOtherSubnetStake(TOKEN1, _netuids(NETUID2), _hotkeys(hotkey3));

        assertEq(bob.balance - bobBefore, 100_000 * 1e9, "0.002 alpha sold at 0.05 TAO per alpha, in wei");
        assertEq(_stakingHotkeyCount(cloneColdkey), 2, "the entry is gone");
        mock.setStake(hotkey3, _toSubstrate(stranger), NETUID2, CRUMB);
        vm.prank(stranger);
        _expectChainRefusal();
        mock.transferStake(cloneColdkey, hotkey3, NETUID2, NETUID2, CRUMB);
    }

    function test_SellOtherSubnetStake_SellsEveryPairOrNone() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _strangerTransfer(hotkey2, cloneColdkey, NETUID2);
        _strangerTransfer(hotkey3, cloneColdkey, NETUID2);
        uint16[] memory netuids = new uint16[](2);
        netuids[0] = uint16(NETUID2);
        netuids[1] = uint16(NETUID2);

        vm.prank(bob);
        vm.expectRevert(ZeroAmount.selector);
        vault.sellOtherSubnetStake(TOKEN1, netuids, _hotkeys(hotkey2, hotkey4));
        assertEq(_getStakeForColdkey(hotkey2, cloneColdkey, NETUID2), CRUMB, "a failed pair sells nothing");

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.sellOtherSubnetStake(TOKEN1, netuids, _hotkeys(hotkey2, hotkey3));

        assertEq(bob.balance - bobBefore, 2 * 100_000 * 1e9, "both crumbs paid out");
        assertEq(_getStakeForColdkey(hotkey2, cloneColdkey, NETUID2), 0);
        assertEq(_getStakeForColdkey(hotkey3, cloneColdkey, NETUID2), 0);
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA, "the backing is untouched");
    }

    function test_RevertWhen_SellingOnTheTokensOwnSubnet() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        vm.expectRevert(NothingToRecover.selector);
        vault.sellOtherSubnetStake(TOKEN1, _netuids(NETUID1), _hotkeys(hotkey1));
    }

    function test_RevertWhen_SellingWithMismatchedArrays() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        vm.expectRevert(MismatchedArrays.selector);
        vault.sellOtherSubnetStake(TOKEN1, _netuids(NETUID2), _hotkeys(hotkey1, hotkey2));
    }

    function test_RevertWhen_SellingNothing() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        vm.expectRevert(ZeroAmount.selector);
        vault.sellOtherSubnetStake(TOKEN1, new uint16[](0), new bytes32[](0));
    }

    function test_RevertWhen_SellingForAnUnpreparedToken() public {
        vm.expectRevert(NothingToRecover.selector);
        vault.sellOtherSubnetStake(TOKEN1, _netuids(NETUID2), _hotkeys(hotkey1));
    }

    function test_RevertWhen_AnOwnMoveWouldPassTheListCap_UntilACrumbIsSold() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        bytes32 firstCrumb = _plantCrumbsOnOtherSubnet(cloneColdkey, MAX_STAKING_HOTKEYS - 3);
        assertEq(_stakingHotkeyCount(cloneColdkey), MAX_STAKING_HOTKEYS);
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey4), _weights(3334, 3333, 3333));
        _simulateAlphaDeposit(bob, NETUID1, 6 * ALPHA);

        vm.prank(bob);
        vm.expectRevert(StakingListFull.selector);
        vault.wrap(NETUID1, hotkey4, 0);

        vm.prank(bob);
        vault.sellOtherSubnetStake(TOKEN1, _netuids(NETUID2), _hotkeys(firstCrumb));
        _wrapHotkey(bob, NETUID1, hotkey4);

        assertEq(lens.totalStake(TOKEN1), 36 * ALPHA, "the deposit lands once the list has room");
        assertGt(_getVaultStake(hotkey4, NETUID1), 0);
    }

    function test_RevertWhen_ParkingWouldPassTheListCap_UntilACrumbIsSold() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        bytes32 firstCrumb = _plantCrumbsOnOtherSubnet(cloneColdkey, MAX_STAKING_HOTKEYS - 1);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        assertEq(_stakingHotkeyCount(cloneColdkey), MAX_STAKING_HOTKEYS, "the swap renamed one entry");
        vault.syncBacking(TOKEN1);
        assertEq(lens.missingStake(TOKEN1), 30 * ALPHA, "the loss is declared with nothing located");

        vm.expectRevert(StakingListFull.selector);
        vault.recoverStray(TOKEN1, hotkey4);

        vm.prank(bob);
        vault.sellOtherSubnetStake(TOKEN1, _netuids(NETUID2), _hotkeys(firstCrumb));
        vault.recoverStray(TOKEN1, hotkey4);
        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "the found alpha rests on the parking hotkey");
        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallCleared(TOKEN1);
        vault.syncBacking(TOKEN1);

        assertTrue(vault.awaitingAttestation(TOKEN1));
        assertTrue(lens.isBackingIntact(TOKEN1));
    }
}
