// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CloneBase } from "src/CloneBase.sol";
import { DepositMailbox } from "src/DepositMailbox.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { IStaking, STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";

contract CloneBaseTest is AlphaVaultTestBase {
    function test_SellAlphaForTao_NoOpOnZero() public {
        SubnetClone directClone = SubnetClone(Clones.clone(address(subnetLogic)));
        directClone.initialize();
        bytes32 directCloneColdkey = _toSubstrate(address(directClone));
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, directCloneColdkey, NETUID1, 50 * ALPHA);
        vm.expectCall(STAKING_PRECOMPILE, abi.encodeWithSelector(IStaking.removeStake.selector), 0);

        directClone.sellAlphaForTao(hotkey1, NETUID1, 0);

        assertEq(address(directClone).balance, 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, directCloneColdkey, NETUID1), 50 * ALPHA);
    }

    function test_TransferStakeAndHotkey_NoOpOnZero() public {
        DepositMailbox directMailbox = DepositMailbox(Clones.clone(address(mailboxLogic)));
        directMailbox.initialize();
        vm.expectCall(STAKING_PRECOMPILE, abi.encodeWithSelector(IStaking.transferStakeAndHotkey.selector), 0);

        directMailbox.transferStakeAndHotkey(_toSubstrate(bob), hotkey1, hotkey2, uint16(NETUID1), 0);
    }

    function test_RevertWhen_NonWrapperFlushesMailboxAlpha() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        address mailbox = vault.getDepositAddress(alice, NETUID1);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        CloneBase(mailbox).flush(_toSubstrate(bob), hotkey1, NETUID1, 10 * ALPHA);
    }

    function test_RevertWhen_NonWrapperTransfersMailboxAlphaAndHotkey() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        address mailbox = vault.getDepositAddress(alice, NETUID1);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        DepositMailbox(mailbox)
            .transferStakeAndHotkey(
                _toSubstrate(bob), _toSubstrate(mailbox), hotkey1, uint16(NETUID1), uint64(10 * ALPHA)
            );
    }

    function test_RevertWhen_NonWrapperSellsMailboxAlpha() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        address mailbox = vault.getDepositAddress(alice, NETUID1);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        CloneBase(mailbox).sellAlphaForTao(hotkey1, NETUID1, 10 * ALPHA);
    }

    function test_RevertWhen_NonWrapperMovesSubnetCloneStake() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        address vaultClone = vault.subnetClone(TOKEN1);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(vaultClone).moveStake(hotkey1, hotkey2, NETUID1, 1 * ALPHA);
    }

    function test_RevertWhen_NonWrapperTogglesTheGrowthFlag() public {
        _prepareMailbox(alice, NETUID1);
        address vaultClone = vault.subnetClone(TOKEN1);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(vaultClone).setRejectStakingHotkeyGrowth(false);
    }

    function test_RevertWhen_NonWrapperUnwrapsSubnetCloneTao() public {
        _prepareMailbox(alice, NETUID1);
        address vaultClone = vault.subnetClone(TOKEN1);
        _donateToClone(vaultClone, 5 * TAO);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(vaultClone).unwrapTao(payable(bob), 5 * TAO);
    }

    function test_RevertWhen_NonWrapperMovesSubnetCloneTao() public {
        _prepareMailbox(alice, NETUID1);
        address vaultClone = vault.subnetClone(TOKEN1);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(vaultClone).transferAllTao(_toSubstrate(bob));
    }

    function test_RevertWhen_MailboxIsInitializedAgain() public {
        address mailbox = _prepareMailbox(alice, NETUID1);

        vm.prank(bob);
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        CloneBase(mailbox).initialize();
    }

    function test_RevertWhen_MailboxImplementationIsInitialized() public {
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        mailboxLogic.initialize();
    }

    function test_RevertWhen_SubnetCloneImplementationIsInitialized() public {
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        subnetLogic.initialize();
    }
}
