// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract OwnHotkeyDepositTest is AlphaVaultTestBase {
    address private stranger = makeAddr("stranger");
    MockStaking private mock;

    function setUp() public override {
        super.setUp();
        mock = MockStaking(STAKING_PRECOMPILE);
    }

    function _sendToMailbox(address user, uint256 netuid, bytes32 fromHotkey, uint256 amount) private {
        bytes32 mailboxColdkey = _mailboxColdkey(user, netuid);
        mock.setStake(fromHotkey, _toSubstrate(user), netuid, amount);
        vm.prank(user);
        mock.transferStakeAndHotkey(
            mailboxColdkey, fromHotkey, mailboxColdkey, uint16(netuid), uint16(netuid), uint64(amount)
        );
    }

    function _giftFromStranger(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amount) private {
        mock.setStake(hotkey, _toSubstrate(stranger), netuid, amount);
        vm.prank(stranger);
        mock.transferStake(coldkey, hotkey, netuid, netuid, amount);
    }

    function testFuzz_Deposit_TravelsFromTheMailboxHotkeyToTheChosenValidator(uint256 amount) public {
        amount = bound(amount, ALPHA, 100_000 * ALPHA);
        _prepareMailbox(alice, NETUID1);
        bytes32 mailboxColdkey = _mailboxColdkey(alice, NETUID1);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _sendToMailbox(alice, NETUID1, hotkey2, amount);

        _wrapHotkey(alice, NETUID1, hotkey2);

        assertEq(vault.balanceOf(alice, TOKEN1), amount * 1e9, "a first deposit mints 1e9 shares per RAO");
        assertEq(lens.totalStake(TOKEN1), amount, "the whole deposit backs the position");
        assertEq(_getStakeForColdkey(mailboxColdkey, mailboxColdkey, NETUID1), 0, "the mailbox hotkey is empty");
        assertEq(_getStakeForColdkey(cloneColdkey, cloneColdkey, NETUID1), 0, "the clone hotkey is empty");
        assertEq(_stakingHotkeyCount(mailboxColdkey), 0, "an empty mailbox lists nothing");
        assertEq(_stakingHotkeyCount(cloneColdkey), 3, "the clone lists the attested set");
    }

    function test_Deposit_LandsAgainAfterBothOwnHotkeysDrained() public {
        _prepareMailbox(alice, NETUID1);
        _sendToMailbox(alice, NETUID1, hotkey1, 10 * ALPHA);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _sendToMailbox(alice, NETUID1, hotkey1, 5 * ALPHA);
        _wrapHotkey(alice, NETUID1, hotkey3);

        assertEq(lens.totalStake(TOKEN1), 15 * ALPHA, "both deposits back the position");
    }

    function test_StrangerCannotAddHotkeysToAClone_ButADepositStillLands() public {
        (address mailbox, address clone) = _prepareMailboxAndClone(alice, NETUID1);
        bytes32 strangerHotkey = keccak256("stranger hotkey");
        mock.setHotkeyOwned(strangerHotkey, true);
        mock.setStake(strangerHotkey, _toSubstrate(stranger), NETUID2, 2 * ALPHA);
        for (uint256 i; i < 2; ++i) {
            bytes32 target = i == 0 ? _toSubstrate(mailbox) : _toSubstrate(clone);
            vm.prank(stranger);
            _expectChainRefusal();
            mock.transferStake(target, strangerHotkey, NETUID2, NETUID2, ALPHA);
            assertEq(_stakingHotkeyCount(target), 1, "only the own hotkey is listed");
        }

        _sendToMailbox(alice, NETUID1, hotkey1, 10 * ALPHA);
        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
    }

    function test_GiftOnTheClonesOwnHotkey_IsCollectedByRecoverStray() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 cloneColdkey = _subnetColdkey(NETUID1);
        _giftFromStranger(cloneColdkey, cloneColdkey, NETUID1, 3 * ALPHA);

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, hotkey1, 3 * ALPHA);
        vault.recoverStray(TOKEN1, cloneColdkey);

        assertEq(lens.totalStake(TOKEN1), 33 * ALPHA, "the gift joined the backing");
        assertEq(_getStakeForColdkey(cloneColdkey, cloneColdkey, NETUID1), 0);
    }

    function _prepareMailboxAndClone(address user, uint256 netuid) private returns (address mailbox, address clone) {
        mailbox = _prepareMailbox(user, netuid);
        clone = vault.subnetClone(vault.currentTokenId(netuid));
    }
}
