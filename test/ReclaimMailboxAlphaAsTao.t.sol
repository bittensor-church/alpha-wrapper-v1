// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { LockedDeposit, MailboxNotPrepared, NetuidOutOfRange, SlippageExceeded, ZeroAmount } from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { ReentrantReceiver, RevertingReceiver } from "./helpers/TaoRailReceivers.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ReclaimMailboxAlphaAsTaoTest is AlphaVaultTestBase {
    function _seedMailboxAlpha(address user, uint256 netuid, uint256 amount) internal {
        bytes32 mailboxColdkey = _toSubstrate(_prepareMailbox(user, netuid));
        MockStaking(STAKING_PRECOMPILE).setStake(mailboxColdkey, mailboxColdkey, netuid, amount);
    }

    function _mailboxStake(address user) internal view returns (uint256) {
        bytes32 mailboxColdkey = _mailboxColdkey(user, NETUID1);
        return _getStakeForColdkey(mailboxColdkey, mailboxColdkey, NETUID1);
    }

    function test_ReclaimMailboxAlphaAsTao_DrainsMailboxAndPaysCallerInTao() public {
        _seedMailboxAlpha(alice, NETUID1, 100 * ALPHA);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.reclaimMailboxAlphaAsTao(NETUID1, 0);

        assertEq(alice.balance - before, 5 * TAO, "100 alpha at 0.05 TAO per alpha");
        assertEq(_mailboxStake(alice), 0);
    }

    function test_ReclaimMailboxAlphaAsTao_ZeroMinTaoOutAcceptsPriceImpact() public {
        _seedMailboxAlpha(alice, NETUID1, 100 * ALPHA);
        _setRemoveStakeRate(1, 25);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.reclaimMailboxAlphaAsTao(NETUID1, 0);

        assertEq(alice.balance - before, 4 * TAO, "100 alpha realized at 0.04 TAO per alpha");
        assertEq(_mailboxStake(alice), 0);
    }

    function test_TwoUsersOnSameNetuid_MailboxesAreIsolated() public {
        _seedMailboxAlpha(alice, NETUID1, 100 * ALPHA);
        _seedMailboxAlpha(bob, NETUID1, 70 * ALPHA);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.reclaimMailboxAlphaAsTao(NETUID1, 0);

        assertEq(alice.balance - aliceBefore, 5 * TAO);
        assertEq(_mailboxStake(bob), 70 * ALPHA);
    }

    function test_RevertWhen_NetuidExceedsUint16() public {
        vm.prank(alice);
        vm.expectRevert(NetuidOutOfRange.selector);
        vault.reclaimMailboxAlphaAsTao(uint256(type(uint16).max) + 1, 0);
    }

    function test_RevertWhen_NoMailboxPrepared() public {
        vm.prank(alice);
        vm.expectRevert(MailboxNotPrepared.selector);
        vault.reclaimMailboxAlphaAsTao(NETUID1, 0);
    }

    function test_RevertWhen_NoMailboxStakeForGivenHotkey() public {
        _prepareMailbox(alice, NETUID1);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.reclaimMailboxAlphaAsTao(NETUID1, 0);
    }

    function test_RevertWhen_MailboxAlphaIsLocked() public {
        _seedMailboxAlpha(alice, NETUID1, 100 * ALPHA);
        MockStaking(STAKING_PRECOMPILE)
            .setLockedAlpha(_mailboxColdkey(alice, NETUID1), NETUID1, _mailboxColdkey(alice, NETUID1), 40 * ALPHA);

        vm.prank(alice);
        vm.expectRevert(LockedDeposit.selector);
        vault.reclaimMailboxAlphaAsTao(NETUID1, 0);
    }

    function test_RevertWhen_RealizedTaoBelowMinTaoOut() public {
        _seedMailboxAlpha(alice, NETUID1, 100 * ALPHA);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 5 * TAO));
        vault.reclaimMailboxAlphaAsTao(NETUID1, 5 * TAO + 1);
    }

    function test_RevertWhen_RemoveStakeFails() public {
        _seedMailboxAlpha(alice, NETUID1, 100 * ALPHA);
        _setRemoveStakeReverts(true);

        vm.prank(alice);
        _expectChainRefusal();
        vault.reclaimMailboxAlphaAsTao(NETUID1, 0);
    }

    function test_DonationToMailboxPriorToCall_DoesNotInflateTaoOut() public {
        _seedMailboxAlpha(alice, NETUID1, 100 * ALPHA);
        address mailbox = vault.getDepositAddress(alice, NETUID1);
        _donateToClone(mailbox, 1 * TAO);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.reclaimMailboxAlphaAsTao(NETUID1, 0);

        assertEq(alice.balance - before, 5 * TAO);
        assertEq(mailbox.balance, 1 * TAO);
    }

    function test_RevertWhen_CallerReceiverRevertsOnReceive() public {
        RevertingReceiver receiver = new RevertingReceiver();
        _seedMailboxAlpha(address(receiver), NETUID1, 100 * ALPHA);

        vm.prank(address(receiver));
        vm.expectRevert(bytes("nope"));
        vault.reclaimMailboxAlphaAsTao(NETUID1, 0);
    }

    function test_ReentrantReclaimMailboxAlphaAsTaoIsRejectedByGuard() public {
        ReentrantReceiver receiver = new ReentrantReceiver();
        _seedMailboxAlpha(address(receiver), NETUID1, 100 * ALPHA);
        receiver.arm(address(vault), abi.encodeCall(vault.reclaimMailboxAlphaAsTao, (NETUID1, 0)));

        vm.prank(address(receiver));
        vault.reclaimMailboxAlphaAsTao(NETUID1, 0);

        assertEq(receiver.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertFalse(receiver.reentrySucceeded());
        assertEq(_mailboxStake(address(receiver)), 0);
    }

    function test_ReclaimMailboxAlphaAsTao_EmitsMailboxAlphaSoldForTaoEvent() public {
        _seedMailboxAlpha(alice, NETUID1, 100 * ALPHA);

        vm.expectEmit(true, true, true, true, address(vault));
        emit MailboxAlphaSoldForTao(alice, NETUID1, _mailboxColdkey(alice, NETUID1), 100 * ALPHA, 5 * TAO);

        vm.prank(alice);
        vault.reclaimMailboxAlphaAsTao(NETUID1, 0);
    }
}
