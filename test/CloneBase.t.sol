// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CloneBase } from "src/CloneBase.sol";
import { SubnetClone } from "src/SubnetClone.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";

contract CloneBaseTest is AlphaVaultTestBase {
    /// @dev Wrapped by this test, so the test can drive it the way the vault does.
    SubnetClone internal directClone;
    bytes32 internal directCloneColdkey;

    function setUp() public override {
        super.setUp();
        directClone = SubnetClone(payable(Clones.clone(address(subnetLogic))));
        directClone.initialize(address(this));
        directCloneColdkey = _toSubstrate(address(directClone));
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, directCloneColdkey, NETUID1, 50 * ALPHA);
    }

    function test_SellAlphaForTao_CreditsCloneNativeBalance() public {
        directClone.sellAlphaForTao(hotkey1, NETUID1, 40 * ALPHA);

        assertEq(address(directClone).balance, 2 * TAO, "40 alpha at 0.05 TAO/alpha");
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, directCloneColdkey, NETUID1), 10 * ALPHA);
    }

    function test_SellAlphaForTao_NoOpOnZero() public {
        // Make the precompile reject even zero, exposing any missing caller-side zero guard.
        MockStaking(STAKING_PRECOMPILE).setRemoveStakeReverts(true);

        directClone.sellAlphaForTao(hotkey1, NETUID1, 0);

        assertEq(address(directClone).balance, 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, directCloneColdkey, NETUID1), 50 * ALPHA);
    }

    function test_MoveStake_MovesTheAmountBetweenHotkeys() public {
        directClone.moveStake(hotkey1, hotkey2, NETUID1, 50 * ALPHA);

        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, directCloneColdkey, NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey2, directCloneColdkey, NETUID1), 50 * ALPHA);
    }

    function test_UnwrapTao_PaysTheRecipient() public {
        vm.deal(address(directClone), 5 * TAO);
        uint256 aliceBefore = alice.balance;

        directClone.unwrapTao(payable(alice), 5 * TAO);

        assertEq(address(directClone).balance, 0);
        assertEq(alice.balance - aliceBefore, 5 * TAO);
    }

    function test_RevertWhen_NonWrapperFlushesMailboxAlpha() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        address mailbox = vault.getDepositAddress(alice, NETUID1);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        CloneBase(payable(mailbox)).flush(_toSubstrate(bob), hotkey1, NETUID1, 10 * ALPHA);
    }

    function test_RevertWhen_NonWrapperSellsMailboxAlpha() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        address mailbox = vault.getDepositAddress(alice, NETUID1);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        CloneBase(payable(mailbox)).sellAlphaForTao(hotkey1, NETUID1, 10 * ALPHA);
    }

    function test_RevertWhen_NonWrapperMovesSubnetCloneStake() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        address vaultClone = vault.subnetClone(TOKEN1);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(payable(vaultClone)).moveStake(hotkey1, hotkey2, NETUID1, 1 * ALPHA);
    }

    function test_RevertWhen_NonWrapperUnwrapsSubnetCloneTao() public {
        _prepareMailbox(alice, NETUID1);
        address vaultClone = vault.subnetClone(TOKEN1);
        _donateToClone(vaultClone, 5 * TAO);

        vm.prank(bob);
        vm.expectRevert(CloneBase.NotWrapper.selector);
        SubnetClone(payable(vaultClone)).unwrapTao(payable(bob), 5 * TAO);
    }

    function test_RevertWhen_MailboxIsInitializedAgain() public {
        address mailbox = _prepareMailbox(alice, NETUID1);

        vm.prank(bob);
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        CloneBase(payable(mailbox)).initialize(bob);
    }

    function test_RevertWhen_CallerInitializesACloneForAnotherWrapper() public {
        address fresh = Clones.clone(address(mailboxLogic));

        vm.expectRevert(CloneBase.UnauthorizedInitializer.selector);
        CloneBase(payable(fresh)).initialize(bob);
    }

    function test_RevertWhen_MailboxImplementationIsInitialized() public {
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        mailboxLogic.initialize(address(this));
    }

    function test_RevertWhen_SubnetCloneImplementationIsInitialized() public {
        vm.expectRevert(CloneBase.AlreadyInitialized.selector);
        subnetLogic.initialize(address(this));
    }
}
