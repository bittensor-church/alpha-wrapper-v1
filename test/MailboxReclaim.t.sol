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
        _simulateAlphaDeposit(user, NETUID1, 100 * ALPHA);
        mailboxColdkey = _mailboxColdkey(user, NETUID1);
        mock.setLockedAlpha(mailboxColdkey, NETUID1, mailboxColdkey, 40 * ALPHA);
    }

    function test_RevertWhen_ReclaimingLockedAlphaToAColdkeyThatRejectsLocks() public {
        _depositLockedAlpha(alice);

        vm.prank(alice);
        vm.expectRevert(LockedDeposit.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, _toSubstrate(alice));
    }

    function test_ReclaimAlphaFromMailbox_CarriesTheLockToAnAcceptingColdkey() public {
        bytes32 mailboxColdkey = _depositLockedAlpha(alice);
        bytes32 destination = _toSubstrate(alice);
        mock.setAcceptsLockedAlpha(destination, true);

        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, destination);

        assertEq(_getStakeForColdkey(mailboxColdkey, destination, NETUID1), 100 * ALPHA, "the whole deposit arrives");
        assertEq(_getStakeForColdkey(mailboxColdkey, mailboxColdkey, NETUID1), 0, "the mailbox is empty");
        assertEq(mock.lockedAlpha(destination, NETUID1), 40 * ALPHA, "the lock moves with the alpha");
        assertEq(mock.lockHotkey(destination, NETUID1), mailboxColdkey);
        assertEq(mock.lockedAlpha(mailboxColdkey, NETUID1), 0, "and leaves the mailbox");
    }

    function test_RevertWhen_ReclaimingAlphaWithoutAMailbox() public {
        vm.prank(alice);
        vm.expectRevert(MailboxNotPrepared.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, _toSubstrate(alice));
    }

    function test_RevertWhen_ReclaimingTaoFromAnEmptyMailbox() public {
        _prepareMailbox(alice, NETUID1);

        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.reclaimTaoFromMailbox(NETUID1);
    }
}
