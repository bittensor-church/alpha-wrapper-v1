// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { LockedDeposit, MailboxNotPrepared, ZeroAmount } from "src/VaultErrors.sol";
import { MockAlpha } from "./mocks/MockAlpha.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract MailboxReclaimTest is AlphaVaultTestBase {
    /// @dev 0.3 alpha, below the 0.4-alpha nominator minimum at 0.05 TAO/alpha, so the network sweep takes it.
    uint256 private constant SWEEPABLE_DEPOSIT = 300_000_000;

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

    function _depositSweepableDust() internal returns (bytes32 mailboxColdkey) {
        _simulateAlphaDepositHotkey(alice, NETUID1, SWEEPABLE_DEPOSIT, hotkey1);
        mailboxColdkey = _mailboxColdkey(alice, NETUID1);
    }

    function _sweepDust(bytes32 mailboxColdkey) internal {
        mock.sweepSmallNomination(hotkey1, vault.getDepositAddress(alice, NETUID1), NETUID1);
        assertEq(_getStakeForColdkey(hotkey1, mailboxColdkey, NETUID1), 0, "the sweep deleted the deposit");
    }

    /// @dev The chain cannot sell locked alpha, so its sweep deletes the deposit unpaid.
    function test_RevertWhen_ReclaimingTaoAfterTheSweepDeletedALockedDeposit() public {
        bytes32 mailboxColdkey = _depositSweepableDust();
        mock.setLockedAlpha(mailboxColdkey, NETUID1, hotkey1, SWEEPABLE_DEPOSIT);

        _sweepDust(mailboxColdkey);

        assertEq(mock.lockedAlpha(mailboxColdkey, NETUID1), 0, "the sweep released the lock");
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.reclaimTaoFromMailbox(NETUID1);
    }

    /// @dev The sweep sells through the pool; when the pool cannot fill the sale, the deposit is deleted unpaid.
    function test_RevertWhen_ReclaimingTaoAfterThePoolRefusedTheSweep() public {
        bytes32 mailboxColdkey = _depositSweepableDust();
        MockAlpha(ALPHA_PRECOMPILE).setSimSwapRefused(uint64(SWEEPABLE_DEPOSIT), true);

        _sweepDust(mailboxColdkey);

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
