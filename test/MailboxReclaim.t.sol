// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { DepositScenarios } from "./helpers/DepositScenarios.sol";
import { LockedDeposit, MailboxNotPrepared, ZeroAmount } from "src/VaultErrors.sol";

contract MailboxReclaimTest is DepositScenarios {
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

    function test_ReclaimAlphaFromMailbox_EmptiesALockedMailboxIntoAnAcceptingColdkey() public {
        bytes32 mailboxColdkey = _depositLockedAlpha(alice);
        bytes32 destination = _toSubstrate(alice);
        mock.setAcceptsLockedAlpha(destination, true);

        vm.expectEmit(true, true, false, true, address(vault));
        emit MailboxAlphaReclaimed(alice, NETUID1, destination, 100 * ALPHA);
        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, destination);

        assertEq(_getStakeForColdkey(mailboxColdkey, destination, NETUID1), 100 * ALPHA, "the whole deposit arrives");
        assertEq(_getStakeForColdkey(mailboxColdkey, mailboxColdkey, NETUID1), 0, "the mailbox is empty");

        assertEq(_depositAndWrap(alice, NETUID1, 10 * ALPHA), 10e18, "the emptied mailbox takes a new deposit");
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
