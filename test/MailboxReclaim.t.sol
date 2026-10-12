// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { LockedDeposit, MailboxNotPrepared, ZeroAmount } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract MailboxReclaimTest is AlphaVaultTestBase {
    MockStaking internal mock;

    function setUp() public override {
        super.setUp();
        mock = MockStaking(STAKING_PRECOMPILE);
    }

    function _depositLockedAlpha(address user) internal returns (bytes32 mailboxColdkey) {
        _simulateAlphaDepositHotkey(user, NETUID1, 100 * ALPHA, hotkey1);
        mailboxColdkey = _mailboxColdkey(user, NETUID1);
        mock.setLockedAlpha(mailboxColdkey, NETUID1, hotkey1, 40 * ALPHA);
    }

    function test_RevertWhen_ReclaimingLockedAlphaToAColdkeyThatRejectsLocks() public {
        _depositLockedAlpha(alice);

        vm.prank(alice);
        vm.expectRevert(LockedDeposit.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey1, _toSubstrate(alice));
    }

    function test_ReclaimAlphaFromMailbox_CarriesTheLockToAnAcceptingColdkey() public {
        bytes32 mailboxColdkey = _depositLockedAlpha(alice);
        bytes32 destination = _toSubstrate(alice);
        mock.setAcceptsLockedAlpha(destination, true);

        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey1, destination);

        assertEq(_getStakeForColdkey(hotkey1, destination, NETUID1), 100 * ALPHA, "the whole deposit arrives");
        assertEq(_getStakeForColdkey(hotkey1, mailboxColdkey, NETUID1), 0, "the mailbox is empty");
        assertEq(mock.lockedAlpha(destination, NETUID1), 40 * ALPHA, "the lock moves with the alpha");
        assertEq(mock.lockHotkey(destination, NETUID1), hotkey1);
        assertEq(mock.lockedAlpha(mailboxColdkey, NETUID1), 0, "and leaves the mailbox");
    }

    /// @dev Alice locks to hotkey1 while her stake sits on hotkey2. Renaming hotkey1 to hotkey5 carries her lock, so a
    ///      locked deposit on hotkey5 can join it.
    function test_ReclaimAlphaFromMailbox_JoinsALockThatFollowedARename() public {
        bytes32 destination = _toSubstrate(alice);
        mock.setStake(hotkey2, destination, NETUID1, 10 * ALPHA);
        mock.setLockedAlpha(destination, NETUID1, hotkey1, 10 * ALPHA);
        mock.setAcceptsLockedAlpha(destination, true);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey5);
        _simulateAlphaDepositHotkey(alice, NETUID1, 100 * ALPHA, hotkey5);
        mock.setLockedAlpha(_mailboxColdkey(alice, NETUID1), NETUID1, hotkey5, 40 * ALPHA);

        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey5, destination);

        assertEq(_getStakeForColdkey(hotkey5, destination, NETUID1), 100 * ALPHA, "the whole deposit arrives");
        assertEq(mock.lockedAlpha(destination, NETUID1), 50 * ALPHA, "the deposit's lock joins hers");
        assertEq(mock.lockHotkey(destination, NETUID1), hotkey5);
    }

    /// @dev A 0.3-alpha deposit sits below the 0.4-alpha nominator minimum at 0.05 TAO/alpha. The chain cannot sell
    ///      locked alpha, so its sweep deletes the deposit unpaid.
    function test_RevertWhen_ReclaimingTaoAfterTheSweepDeletedALockedDeposit() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 300_000_000, hotkey1);
        bytes32 mailboxColdkey = _mailboxColdkey(alice, NETUID1);
        mock.setLockedAlpha(mailboxColdkey, NETUID1, hotkey1, 300_000_000);

        mock.sweepSmallNomination(hotkey1, vault.getDepositAddress(alice, NETUID1), NETUID1);

        assertEq(_getStakeForColdkey(hotkey1, mailboxColdkey, NETUID1), 0, "the sweep deleted the deposit");
        assertEq(mock.lockedAlpha(mailboxColdkey, NETUID1), 0, "and released its lock");
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.reclaimTaoFromMailbox(NETUID1);
    }

    function test_RevertWhen_ReclaimingAlphaWithoutAMailbox() public {
        vm.prank(alice);
        vm.expectRevert(MailboxNotPrepared.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey1, _toSubstrate(alice));
    }

    function test_RevertWhen_ReclaimingTaoFromAnEmptyMailbox() public {
        _prepareMailbox(alice, NETUID1);

        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.reclaimTaoFromMailbox(NETUID1);
    }
}
