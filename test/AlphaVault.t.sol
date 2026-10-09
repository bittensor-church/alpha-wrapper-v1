// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { Vm } from "forge-std/Test.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import {
    AlphaTransfersDisabled,
    ChosenHotkeyNotInSet,
    ClaimBelowNativePrecision,
    InsufficientShares,
    NetuidOutOfRange,
    NoSharesOutstanding,
    NothingToUnwrap,
    NoValidatorFound,
    ParkingHotkeyUnavailable,
    SubnetDissolved,
    SlippageExceeded,
    SubnetInDissolutionBlackoutPeriod,
    SubnetNotRegistered,
    ValidatorSetMalformed,
    WithdrawTooSmall,
    ZeroAddress,
    ZeroAmount,
    MailboxNotPrepared,
    ZeroColdkey,
    ZeroHotkey
} from "src/VaultErrors.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { MockValidatorRegistry } from "./mocks/MockValidatorRegistry.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract AlphaVaultTest is AlphaVaultTestBase {
    function test_RevertWhen_ConstructorZeroMailboxLogic() public {
        vm.expectRevert(ZeroAddress.selector);
        new AlphaVault(VAULT_URI, address(0), address(subnetLogic), address(registry), RECOVERY_WINDOW, PARKING_HOTKEY);
    }

    function test_RevertWhen_ConstructorZeroSubnetLogic() public {
        vm.expectRevert(ZeroAddress.selector);
        new AlphaVault(VAULT_URI, address(mailboxLogic), address(0), address(registry), RECOVERY_WINDOW, PARKING_HOTKEY);
    }

    function test_RevertWhen_ConstructorZeroValidatorRegistry() public {
        vm.expectRevert(ZeroAddress.selector);
        new AlphaVault(
            VAULT_URI, address(mailboxLogic), address(subnetLogic), address(0), RECOVERY_WINDOW, PARKING_HOTKEY
        );
    }

    function test_RevertWhen_ConstructorZeroRecoveryWindow() public {
        vm.expectRevert(ZeroAmount.selector);
        new AlphaVault(VAULT_URI, address(mailboxLogic), address(subnetLogic), address(registry), 0, PARKING_HOTKEY);
    }

    function test_RevertWhen_ConstructorZeroParkingHotkey() public {
        vm.expectRevert(ZeroHotkey.selector);
        new AlphaVault(
            VAULT_URI, address(mailboxLogic), address(subnetLogic), address(registry), RECOVERY_WINDOW, bytes32(0)
        );
    }

    function test_RevertWhen_ConstructorParkingHotkeyIsOwnedByAnotherColdkey() public {
        bytes32 taken = keccak256("taken-parking-hotkey");
        _simulateSquatter(taken);

        vm.expectRevert(ParkingHotkeyUnavailable.selector);
        new AlphaVault(
            VAULT_URI, address(mailboxLogic), address(subnetLogic), address(registry), RECOVERY_WINDOW, taken
        );
    }

    function test_Constructor_ClaimsTheParkingHotkeyForTheVault() public view {
        (bool exists, bytes32 owner) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(vault.parkingHotkey());
        assertTrue(exists, "the parking hotkey has an owner record");
        assertEq(owner, _toSubstrate(address(vault)), "held by the vault's own coldkey");
    }

    function test_CreateMailbox_PublishesTheCloneOnceAndOneMailboxPerUserAndNetuid() public {
        assertEq(vault.subnetClone(TOKEN1), address(0));

        vm.recordLogs();
        address aliceMailbox = _prepareMailbox(alice, NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "the first caller publishes the clone and a mailbox");
        assertEq(logs[0].emitter, address(vault));
        assertEq(logs[0].topics[0], SubnetProxyCreated.selector);
        assertEq(logs[0].topics[1], bytes32(TOKEN1));
        assertEq(abi.decode(logs[0].data, (address)), vault.subnetClone(TOKEN1));
        _assertMailboxCreated(logs[1], alice, NETUID1, aliceMailbox);

        vm.recordLogs();
        address bobMailbox = _prepareMailbox(bob, NETUID1);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "later callers share the clone");
        _assertMailboxCreated(logs[0], bob, NETUID1, bobMailbox);

        address aliceMailboxOnNetuid2 = _prepareMailbox(alice, NETUID2);
        assertTrue(aliceMailbox != bobMailbox, "one mailbox per user");
        assertTrue(aliceMailbox != aliceMailboxOnNetuid2, "and per netuid");
        assertEq(vault.getDepositAddress(alice, NETUID1), aliceMailbox);
        assertEq(vault.getDepositAddress(alice, NETUID2), aliceMailboxOnNetuid2);
    }

    function _assertMailboxCreated(Vm.Log memory entry, address user, uint256 netuid, address mailbox) private view {
        assertEq(entry.emitter, address(vault));
        assertEq(entry.topics[0], MailboxCreated.selector);
        assertEq(entry.topics[1], bytes32(uint256(uint160(user))));
        assertEq(entry.topics[2], bytes32(netuid));
        assertEq(abi.decode(entry.data, (address)), mailbox);
    }

    function test_Wrap() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Deposited(alice, TOKEN1, 10 * ALPHA, 1e19);
        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(vault.balanceOf(alice, TOKEN1), 1e19, "a first deposit mints 1e9 shares per RAO");
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 10 * ALPHA);
    }

    function test_WrapMultipleSubnets() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);

        _simulateAlphaDeposit(alice, NETUID2, 5 * ALPHA);
        _wrap(alice, NETUID2);

        assertEq(vault.balanceOf(alice, TOKEN1), 1e19);
        assertEq(vault.balanceOf(alice, TOKEN2), 5e18);
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
        assertEq(lens.totalStake(TOKEN2), 5 * ALPHA);
    }

    function test_WrapTwice() public {
        _simulateAlphaDeposit(alice, NETUID1, 5 * ALPHA);
        _wrap(alice, NETUID1);
        assertEq(vault.balanceOf(alice, TOKEN1), 5e18);

        _simulateAlphaDeposit(alice, NETUID1, 5 * ALPHA);
        // 5e9 * (5e18 + 1e9) / (5e9 + 1) = 5e18 exactly.
        vm.expectEmit(true, true, false, true, address(vault));
        emit Deposited(alice, TOKEN1, 5 * ALPHA, 5e18);
        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(vault.balanceOf(alice, TOKEN1), 1e19);
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
    }

    function test_RevertWhen_WrapZero() public {
        _prepareMailbox(alice, NETUID1);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_EarlyWrapperCapturesEmissionsOverLateWrapper() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        _simulateEmissions(NETUID1, 10 * ALPHA);

        uint256 bobShares = _depositAndWrap(bob, NETUID1, 10 * ALPHA);
        // 1e10 * (1e19 + 1e9) / (2e10 + 1): the deposit is priced on the 20 alpha that back the shares.
        assertEq(bobShares, 5_000_000_000_249_999_999, "bob mints at the grown share price");

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        // 1e19 * (3e10 + 1) / (1e19 + bobShares + 1e9), floored.
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 19_999_999_999, "alice keeps the emissions");

        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);
        assertEq(_userStakeAcrossHotkeys(bob, NETUID1), 10 * ALPHA, "bob gets his deposit back");
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 1, "alice's rounding RAO stays behind");
    }

    function test_Unwrap() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 10 * ALPHA);

        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 10 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    function test_RevertWhen_GatherDeliversLessThanMinAlphaOut() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        // Both gather hops onto the last slot lose one RAO.
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 10 * ALPHA - 2));
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 10 * ALPHA - 1);
    }

    function test_RevertWhen_RecipientCreditIsBelowMinAlphaOut() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        MockStaking(STAKING_PRECOMPILE).setTransferStakeRoundingLoss(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 10 * ALPHA - 1));
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 10 * ALPHA);
    }

    function test_UnwrapReportsActualRecipientCredit() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        uint256 creditedAlpha = 10 * ALPHA - 1;

        MockStaking(STAKING_PRECOMPILE).setTransferStakeRoundingLoss(1);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Unwrapped(alice, TOKEN1, shares, creditedAlpha);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), creditedAlpha);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), creditedAlpha);
    }

    function test_FirstWrapDoesNotUnderflowWhenRebalanceRounds() public {
        // Real stake moves can round down, one RAO per move here.
        MockStaking(STAKING_PRECOMPILE).setMoveStakeRoundingLoss(1);

        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);

        assertEq(vault.balanceOf(alice, TOKEN1), 1e19, "the mint prices the whole deposit");
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA - 2, "the two weight moves lost one RAO each");
    }

    function test_RevertWhen_UnwrapOnZero() public {
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.unwrap(TOKEN1, 0, aliceSub, 0);
    }

    function test_RevertWhen_LiveUnwrapToZeroColdkey() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        vm.prank(alice);
        vm.expectRevert(ZeroColdkey.selector);
        vault.unwrap(TOKEN1, shares, bytes32(0), 0);
    }

    function testFuzz_PreviewWrapScalesLinearlyOnEmptyVault(uint256 assets) public view {
        assets = bound(assets, 0, MAX_SUBNET_ALPHA);
        assertEq(lens.previewWrap(TOKEN1, assets), assets * 1e9, "an empty vault mints 1e9 shares per RAO");
    }

    function test_PreviewUnwrap() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 10 * ALPHA);
        assertEq(tao, 0);
    }

    function test_UnwrapPartialShares() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        vm.prank(alice);
        vault.unwrap(TOKEN1, 5e18, _toSubstrate(alice), 0);

        assertEq(vault.balanceOf(alice, TOKEN1), 5e18);
        // 5e18 * (1e10 + 1) / (1e19 + 1e9) = 5e9 exactly.
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 5 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 5 * ALPHA);
    }

    function test_InterleavedWrapsUnwraps() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 20 * ALPHA);
        assertEq(aliceShares, 1e19);
        // 2e10 * (1e19 + 1e9) / (1e10 + 1) = 2e19 exactly.
        assertEq(bobShares, 2e19);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        assertEq(vault.balanceOf(alice, TOKEN1), 0);
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 10 * ALPHA);

        assertEq(vault.balanceOf(bob, TOKEN1), bobShares);
        assertEq(lens.totalStake(TOKEN1), 20 * ALPHA);

        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);
        assertEq(vault.balanceOf(bob, TOKEN1), 0);
        assertEq(_userStakeAcrossHotkeys(bob, NETUID1), 20 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 0);
    }

    function test_SubnetIsolation() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        uint256 shares2 = _depositAndWrap(alice, NETUID2, 5 * ALPHA);

        _simulateEmissions(NETUID1, 10 * ALPHA);

        // 1e18 * (2e10 + 1) / (1e19 + 1e9), floored.
        assertEq(lens.sharePrice(TOKEN1), 1_999_999_999, "netuid 1 doubles with its emissions");
        assertEq(lens.sharePrice(TOKEN2), 1e9, "netuid 2 stays at the initial price");

        (uint256 preview2,) = lens.previewUnwrap(TOKEN2, shares2);
        assertEq(preview2, 5 * ALPHA);
    }

    function test_FirstWrapperInflationAttack_CostsTheNextDepositorOneRao() public {
        _simulateAlphaDeposit(alice, NETUID1, ALPHA_FLOOR);
        _wrap(alice, NETUID1);
        assertEq(vault.balanceOf(alice, TOKEN1), 4e16, "the smallest deposit the vault accepts");

        // A 100,000-alpha gift to the clone (5,000 TAO at 0.05) lands like an emission.
        _simulateEmissions(NETUID1, 100_000 * ALPHA);

        uint256 bobShares = _depositAndWrap(bob, NETUID1, 1_000 * ALPHA);
        // 1e12 * (4e16 + 1e9) / (1e14 + 4e7 + 1), floored.
        assertEq(bobShares, 399_999_850_000_055);

        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);
        // bobShares * (1.01e14 + 4e7 + 1) / (4e16 + bobShares + 1e9), floored.
        assertEq(_userStakeAcrossHotkeys(bob, NETUID1), 1_000 * ALPHA - 1, "the gift costs bob one RAO");
    }

    function test_RevertWhen_SharePriceForUnregisteredSubnet() public {
        uint256 tokenId = uint256(uint16(42)) | (uint256(100) << VaultMath.NETUID_BITS);
        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(tokenId);
    }

    function test_RevertWhen_SharePriceWhenSupplyIsZero() public {
        vault.createMailbox(NETUID1, keccak256("fixture-creation"));
        uint256 tokenId = vault.currentTokenId(NETUID1);
        assertEq(vault.totalSupply(tokenId), 0);
        vm.expectRevert(NoSharesOutstanding.selector);
        lens.sharePrice(tokenId);
    }

    function test_RebalanceWithRegistryWeights() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(6000, 4000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 * ALPHA, hotkey1);
        _wrap(alice, NETUID1);

        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 60 * ALPHA);
        assertEq(_getVaultStake(hotkey2, NETUID1), 40 * ALPHA);
    }

    function test_RebalanceThreeValidators() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(5000, 3000, 2000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 * ALPHA, hotkey1);
        _wrap(alice, NETUID1);

        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 50 * ALPHA);
        assertEq(_getVaultStake(hotkey2, NETUID1), 30 * ALPHA);
        assertEq(_getVaultStake(hotkey3, NETUID1), 20 * ALPHA);
    }

    function test_RebalanceNoOpWhenAlreadyBalanced() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(5000, 5000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 50 * ALPHA, hotkey1);
        _wrap(alice, NETUID1);

        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 50 * ALPHA);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey2, _subnetColdkey(NETUID1), NETUID1, 50 * ALPHA);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);
        assertEq(_getVaultStake(hotkey1, NETUID1), 50 * ALPHA);
        assertEq(_getVaultStake(hotkey2, NETUID1), 50 * ALPHA);
    }

    function test_RebalanceNoOpWhenCloneNotDeployed() public {
        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);
        assertEq(vault.subnetClone(TOKEN1), address(0));
        assertEq(lens.totalStake(TOKEN1), 0);
        assertEq(_lastSeen(TOKEN1).length, 0);
    }

    function test_RebalanceEmitsEvent() public {
        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2), _weights(8000, 2000));

        _simulateAlphaDepositHotkey(alice, NETUID1, 100 * ALPHA, hotkey1);
        _wrap(alice, NETUID1);

        _plantVaultStakes(NETUID1, 100 * ALPHA, 0, 0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Rebalanced(TOKEN1, hotkey1, hotkey2, 20 * ALPHA);
        vault.rebalance(NETUID1);
    }

    function test_UnwrapEmitsRebalanced() public {
        _simulateAlphaDepositHotkey(alice, NETUID2, 10 * ALPHA, hotkey2);
        _wrapHotkey(alice, NETUID2, hotkey2);

        // The 5-alpha payout leaves 1 + 4 alpha on hotkey2 + hotkey1 against 60/40 targets of 3 + 2.
        vm.expectEmit(true, true, true, true, address(vault));
        emit Rebalanced(TOKEN2, hotkey1, hotkey2, 2 * ALPHA);

        vm.prank(alice);
        vault.unwrap(TOKEN2, 5e18, _toSubstrate(alice), 0);
    }

    function test_UnwrapEmitsNoRebalancedWhenFullyDrained() public {
        _registerSubnet(99, hotkey4);
        _simulateAlphaDepositHotkey(alice, 99, 10 * ALPHA, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);
        uint256 tokenId = vault.currentTokenId(99);

        uint256 shares = vault.balanceOf(alice, tokenId);
        vm.recordLogs();
        vm.prank(alice);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);
    }

    function test_RevertWhen_RegistryWhenNoValidatorsSet() public {
        (AlphaVault freshVault,) = _deployVaultAndLens(address(new MockValidatorRegistry()));

        vm.prank(alice);
        vm.expectRevert(NoValidatorFound.selector);
        freshVault.wrap(NETUID1, hotkey1, 0);
    }

    function test_TotalStakeMatchesDepositAcrossValidatorSetSizes() public {
        _setValidators(91, _hotkeys(hotkey4), _weights(VaultMath.BPS_BASE));
        _setRegBlock(91, 91);
        _simulateAlphaDepositHotkey(alice, 91, 30 * ALPHA, hotkey4);
        _wrap(alice, 91);
        assertEq(lens.totalStake(vault.currentTokenId(91)), 30 * ALPHA);
        assertEq(_getVaultStake(hotkey4, 91), 30 * ALPHA);

        _simulateAlphaDeposit(alice, NETUID2, 100 * ALPHA);
        _wrap(alice, NETUID2);
        assertEq(lens.totalStake(vault.currentTokenId(NETUID2)), 100 * ALPHA);

        _simulateAlphaDeposit(alice, NETUID1, 90 * ALPHA);
        _wrap(alice, NETUID1);
        assertEq(lens.totalStake(vault.currentTokenId(NETUID1)), 90 * ALPHA);
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 90 * ALPHA);
    }

    function test_Wrap_PreservesZeroWeightRegistrySlot() public {
        registry.setRaw(NETUID1, _hotkeys(bytes32(0), hotkey1, hotkey2), _weights(0, 5_000, 5_000));
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        assertEq(slots.length, 3, "zero entry is retained");
        assertEq(slots[0].logical, bytes32(0));
        assertEq(slots[0].active, bytes32(0));
        assertEq(slots[0].tracked, 0);
        assertEq(slots[1].logical, hotkey1);
        assertEq(slots[1].tracked, 5 * ALPHA);
        assertEq(slots[2].logical, hotkey2);
        assertEq(slots[2].tracked, 5 * ALPHA);
    }

    function test_RevertWhen_RegistryReturnsMismatchedLengths() public {
        MockValidatorRegistry mock = new MockValidatorRegistry();
        (AlphaVault mockVault,) = _deployVaultAndLens(address(mock));

        bytes32[] memory hotkeys = new bytes32[](1);
        uint16[] memory weights = new uint16[](2);
        hotkeys[0] = hotkey4;
        weights[0] = 5_000;
        weights[1] = 5_000;
        mock.setRaw(91, hotkeys, weights);
        _setRegBlock(91, 91);

        vm.prank(alice);
        vm.expectRevert(ValidatorSetMalformed.selector);
        mockVault.wrap(91, hotkey4, 0);
    }

    function test_RevertWhen_ReclaimTaoFromMailboxBeforeCreatingOne() public {
        vm.prank(alice);
        vm.expectRevert(MailboxNotPrepared.selector);
        vault.reclaimTaoFromMailbox(NETUID1);
    }

    function test_ReclaimTaoFromMailbox_PaysOutTheMailboxBalance() public {
        address mailbox = _prepareMailbox(alice, NETUID1);
        vm.deal(mailbox, 2 * TAO);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.reclaimTaoFromMailbox(NETUID1);

        assertEq(alice.balance - aliceBefore, 2 * TAO);
        assertEq(mailbox.balance, 0);
    }

    function test_ReclaimAlphaFromMailbox() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey4);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);

        address mailbox = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, _toSubstrate(mailbox), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, aliceSub, NETUID1), 10 * ALPHA);
    }

    function test_RevertWhen_ReclaimAlphaFromMailboxZeroHotkey() public {
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(ZeroHotkey.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, bytes32(0), aliceSub);
    }

    function test_RevertWhen_ReclaimAlphaFromMailboxNoStake() public {
        _prepareMailbox(alice, NETUID1);
        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);
    }

    function test_RevertWhen_WrapWhileTransfersAreDisabled() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _setTransfersEnabled(NETUID1, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AlphaTransfersDisabled.selector, uint16(NETUID1)));
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_RevertWhen_UnwrapWhileTransfersAreDisabled() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _setTransfersEnabled(NETUID1, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AlphaTransfersDisabled.selector, uint16(NETUID1)));
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_ReclaimAlphaFromMailboxWhileTransfersAreDisabled() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey4);
        _setTransfersEnabled(NETUID1, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AlphaTransfersDisabled.selector, uint16(NETUID1)));
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, _toSubstrate(alice));
    }

    /// @dev Anyone can park alpha under the clone's coldkey on an attested name; a deposit on that name
    ///      must price only itself and leave the stray for recovery.
    function test_Wrap_LeavesAStrayOnASupersededNameForRecovery() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateFollowedSwap(NETUID1, hotkey1, hotkey4);
        vault.rebalance(NETUID1);
        MockStaking(STAKING_PRECOMPILE).setStake(hotkey1, _subnetColdkey(NETUID1), NETUID1, 3 * ALPHA);
        _simulateAlphaDepositHotkey(bob, NETUID1, 5 * ALPHA, hotkey1);

        _wrapHotkey(bob, NETUID1, hotkey1);

        // 5e9 * (3e19 + 1e9) / (3e10 + 1) = 5e18 exactly: priced on the 30-alpha backing alone.
        assertEq(vault.balanceOf(bob, TOKEN1), 5e18, "the stray does not dilute the mint");
        assertEq(_getVaultStake(hotkey1, NETUID1), 3 * ALPHA, "the stray stays where recovery can find it");
        assertEq(lens.totalStake(TOKEN1), 35 * ALPHA, "and is not part of the backing yet");
    }

    function test_RevertWhen_ReclaimAlphaFromMailboxZeroColdkey() public {
        vm.prank(alice);
        vm.expectRevert(ZeroColdkey.selector);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, bytes32(0));
    }

    function test_ReclaimAlphaFromMailboxAcceptsInSetHotkey() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey1);
        bytes32 aliceSub = _toSubstrate(alice);

        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey1, aliceSub);

        address mailbox = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(mailbox), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, aliceSub, NETUID1), 10 * ALPHA);
    }

    function test_ReclaimAlphaCleansStrandedHotkeyAlongsideValidDeposit() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey1);
        _simulateAlphaDepositHotkey(alice, NETUID1, 5 * ALPHA, hotkey4);

        _wrapHotkey(alice, NETUID1, hotkey1);
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);

        address mailbox = vault.getDepositAddress(alice, NETUID1);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, _toSubstrate(mailbox), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, aliceSub, NETUID1), 5 * ALPHA);
    }

    function test_ReclaimAlphaFromMailboxRecoversAfterSetRotation() public {
        _setNetuid1Set(hotkey1, hotkey2, hotkey4);
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey4);

        _setNetuid1Set(hotkey1, hotkey2, hotkey3);

        bytes32 aliceSub = _toSubstrate(alice);
        vm.prank(alice);
        vault.reclaimAlphaFromMailbox(NETUID1, hotkey4, aliceSub);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey4, aliceSub, NETUID1), 10 * ALPHA);

        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
    }

    function test_CurrentTokenIdReflectsRegistrationCounter() public {
        _setRegistrations(NETUID1, 3);
        _setRegistrations(NETUID2, 7);
        assertEq(vault.currentTokenId(NETUID1), uint256(uint16(NETUID1)) | (uint256(3) << VaultMath.NETUID_BITS));
        assertEq(vault.currentTokenId(NETUID2), uint256(uint16(NETUID2)) | (uint256(7) << VaultMath.NETUID_BITS));
    }

    function test_RevertWhen_CurrentTokenIdForUnregisteredNetuid() public {
        vm.expectRevert(SubnetNotRegistered.selector);
        vault.currentTokenId(42);
    }

    function testFuzz_CurrentTokenId_FollowsTheRegistrationCounterNotTheBlock(
        uint16 netuid,
        uint64 registrations,
        uint64 regBlock
    ) public {
        netuid = uint16(bound(netuid, 1, type(uint16).max));
        regBlock = uint64(bound(regBlock, 1, type(uint64).max));
        _setRegBlock(netuid, regBlock);
        _setRegistrations(netuid, registrations);

        uint256 tokenId = vault.currentTokenId(netuid);
        assertEq(tokenId, uint256(netuid) | (uint256(registrations) << VaultMath.NETUID_BITS));

        _setRegBlock(netuid, regBlock == type(uint64).max ? 1 : type(uint64).max);
        assertEq(vault.currentTokenId(netuid), tokenId, "a rewritten block changes nothing");

        _setRegistrations(netuid, registrations == type(uint64).max ? 0 : registrations + 1);
        vm.expectRevert(SubnetDissolved.selector);
        lens.previewWrap(tokenId, 1e9);
    }

    function testFuzz_RevertWhen_CurrentTokenIdNetuidOutOfRange(uint256 netuid) public {
        netuid = bound(netuid, uint256(type(uint16).max) + 1, type(uint256).max);

        vm.expectRevert(NetuidOutOfRange.selector);
        vault.currentTokenId(netuid);
    }

    function test_RevertWhen_NetuidOutOfRangeAllEntrypoints() public {
        uint256 oob = uint256(type(uint16).max) + 1;

        vm.expectRevert(NetuidOutOfRange.selector);
        vault.currentTokenId(oob);

        vm.expectRevert(NetuidOutOfRange.selector);
        vault.getDepositAddress(alice, oob);
    }

    function test_CurrentTokenIdChangesAfterRecycle() public {
        _reregisterSubnet(NETUID1);
        assertEq(vault.currentTokenId(NETUID1), uint256(uint16(NETUID1)) | (uint256(1) << VaultMath.NETUID_BITS));
    }

    /// @dev Chain migrations have rewritten live subnets' registration blocks; the token must not notice.
    function test_CurrentTokenId_SurvivesARegistrationBlockRewrite() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        _setRegBlock(NETUID1, 100 + 13 * 7200);

        assertEq(vault.currentTokenId(NETUID1), TOKEN1, "the token follows the registration counter");
        assertTrue(lens.isBackingIntact(TOKEN1), "and its record is untouched");
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares / 2, _toSubstrate(alice), 0);
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 5 * ALPHA, "exits still pay in alpha");
        _depositAndWrap(bob, NETUID1, 4 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 9 * ALPHA, "and deposits still land on the same position");
    }

    function test_RevertWhen_CreateMailboxSubnetNotRegistered() public {
        vm.expectRevert(SubnetNotRegistered.selector);
        vault.createMailbox(42, keccak256("fixture-creation"));
    }

    function test_WrapTwoUsersProportionalShares() public {
        assertEq(_depositAndWrap(alice, NETUID1, 10 * ALPHA), 1e19);
        // 3e10 * (1e19 + 1e9) / (1e10 + 1) = 3e19 exactly.
        assertEq(_depositAndWrap(bob, NETUID1, 30 * ALPHA), 3e19);
    }

    function test_RevertWhen_WrapSubnetNotRegistered() public {
        vm.prank(alice);
        vm.expectRevert(SubnetNotRegistered.selector);
        vault.wrap(42, hotkey1, 0);
    }

    function test_WrapAfterRecycleDeploysNewCloneAndIsolatesOldShares() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);
        uint256 oldTokenId = vault.currentTokenId(NETUID1);

        _reregisterSubnet(NETUID1);

        _depositAndWrap(bob, NETUID1, 5 * ALPHA);
        uint256 newTokenId = vault.currentTokenId(NETUID1);

        assertEq(vault.balanceOf(alice, oldTokenId), 1e19);
        assertEq(vault.balanceOf(alice, newTokenId), 0);
        assertEq(vault.balanceOf(bob, newTokenId), 5e18);
        assertEq(vault.balanceOf(bob, oldTokenId), 0);
        assertTrue(vault.subnetClone(oldTokenId) != vault.subnetClone(newTokenId));
    }

    function test_RevertWhen_UnwrapInsufficientShares() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        vm.prank(alice);
        vm.expectRevert(InsufficientShares.selector);
        vault.unwrap(TOKEN1, shares + 1, _toSubstrate(alice), 0);
    }

    function test_UnwrapFromDissolvedSingleHolderDrainsFullPot() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, false, true, address(vault));
        emit DissolvedSubnetUnwrapped(alice, TOKEN1, shares, 5 * TAO);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, 5 * TAO);
        assertEq(vault.totalSupply(TOKEN1), 0);
    }

    function test_RevertWhen_DissolvedUnwrapHasPositiveMinAlphaOut() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 0));
        vault.unwrap(TOKEN1, shares, bytes32(0), 1);
    }

    function test_UnwrapFromDissolvedSubnetTwoHoldersProRata() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 20 * ALPHA);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 60 * ALPHA);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 4 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, 1 * TAO, "a quarter of the shares, a quarter of the pot");

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);
        assertEq(bob.balance - bobBefore, 3 * TAO);
        assertEq(vault.subnetClone(TOKEN1).balance, 0);
        assertEq(vault.totalSupply(TOKEN1), 0);
    }

    function test_DissolvedUnwrap_PaysWholeRaoAndKeepsTheTail() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO + 5e8);
        _simulateDissolutionCompleted(NETUID1);

        (, uint256 quoted) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(quoted, 5 * TAO, "the quote is what the transfer delivers");

        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, false, true, address(vault));
        emit DissolvedSubnetUnwrapped(alice, TOKEN1, shares, 5 * TAO);
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, bytes32(0), 0);

        assertEq(alice.balance - aliceBefore, 5 * TAO, "paid in whole RAO");
        assertEq(clone.balance, 5e8, "the sub-RAO tail stays behind");
    }

    function test_RevertWhen_DissolvedSliceIsBelowOneRao() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, ALPHA_FLOOR);
        _depositAndWrap(bob, NETUID1, 100_000 * ALPHA);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, TAO / 1000);
        _simulateDissolutionCompleted(NETUID1);

        // 1e15 * 4e16 / (4e16 + 1e23) = 399,999,840 wei, below one RAO.
        (, uint256 quoted) = lens.previewUnwrap(TOKEN1, aliceShares);
        assertEq(quoted, 0, "a slice below one RAO quotes nothing");

        vm.prank(alice);
        vm.expectRevert(ClaimBelowNativePrecision.selector);
        vault.unwrap(TOKEN1, aliceShares, bytes32(0), 0);
    }

    function test_UnwrapFromDissolvedSubnetAfterNewSubnetRegistered() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, 5 * TAO);
    }

    function test_TwoDissolvedGenerationsPayFromTheirOwnClones() public {
        uint256 gen1 = TOKEN1;
        uint256 gen1Shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        address clone1 = vault.subnetClone(gen1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(gen1, 5 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        _reregisterSubnet(NETUID1);
        uint256 gen2Shares = _depositAndWrap(alice, NETUID1, 40 * ALPHA);
        uint256 gen2 = vault.currentTokenId(NETUID1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(gen2, 2 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        assertEq(clone1.balance, 5 * TAO);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrap(gen2, gen2Shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - before, 2 * TAO);

        before = alice.balance;
        vm.prank(alice);
        vault.unwrap(gen1, gen1Shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - before, 5 * TAO);
    }

    function test_Unwrap_ReplacedGenerationPaysDuringSuccessorBlackout() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);
        _simulateDissolutionStarted(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, 5 * TAO);
    }

    /// @dev A cleared registration block makes successor cleanup indistinguishable from this token's own.
    function test_Unwrap_RefundsThroughASuccessorsLateCleanup() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);
        _simulateDissolutionStarted(NETUID1);
        _setRegBlock(NETUID1, 0);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);
        assertEq(alice.balance - before, 5 * TAO, "the successor's cleanup does not hold the old refund");
    }

    function test_RevertWhen_UnwrapForTaoOnReplacedGenerationDuringSuccessorBlackout() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);
        _simulateDissolutionStarted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(NothingToUnwrap.selector);
        vault.unwrapForTao(TOKEN1, shares, 0);
    }

    function test_RevertWhen_SharePriceOnReplacedGenerationDuringSuccessorBlackout() public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);
        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(TOKEN1);
    }

    function test_UnwrapSucceedsAfterCleanupCompletesAfterForceSend() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _reregisterSubnet(NETUID1);
        _simulateDissolutionStarted(NETUID1);
        vm.deal(vault.subnetClone(TOKEN1), 1);

        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO);

        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(alice.balance - aliceBefore, 5 * TAO, "the force-sent wei is below one RAO and stays behind");
    }

    function test_RevertWhen_WrapDuringBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _simulateDissolutionStarted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_RevertWhen_UnwrapDuringEarlyBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_UnwrapDuringLateBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, TAO / 2);
        _setRegBlock(NETUID1, 0);

        vm.prank(alice);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrap(tokenId, shares, _toSubstrate(alice), 0);
    }

    function test_RevertWhen_UnwrapForTaoDuringBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);

        vm.prank(alice);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrapForTao(tokenId, shares, 0);
    }

    function test_RevertWhen_UnwrapForTaoDuringLateBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);
        uint256 tokenId = vault.currentTokenId(NETUID1);
        uint256 shares = vault.balanceOf(alice, tokenId);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(tokenId, TAO / 2);
        _setRegBlock(NETUID1, 0);

        vm.prank(alice);
        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.unwrapForTao(tokenId, shares, 0);
    }

    function test_RevertWhen_RebalanceDuringBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);

        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        vault.rebalance(NETUID1);
    }

    function test_RevertWhen_WrapDuringLateBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);

        _simulateDissolutionStarted(NETUID1);
        _setRegBlock(NETUID1, 0);

        vm.prank(alice);
        vm.expectRevert(SubnetNotRegistered.selector);
        vault.wrap(NETUID1, hotkey1, 0);
    }

    function test_RevertWhen_RebalanceDuringLateBlackout() public {
        _simulateAlphaDeposit(alice, NETUID1, 10 * ALPHA);
        _wrap(alice, NETUID1);

        _simulateDissolutionStarted(NETUID1);
        _setRegBlock(NETUID1, 0);

        vm.expectRevert(SubnetNotRegistered.selector);
        vault.rebalance(NETUID1);
    }

    function test_PreviewUnwrap_QuotesTheDissolutionRefund() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 0);
        assertEq(tao, 5 * TAO);
    }

    function test_PreviewUnwrap_QuotesReplacedGenerationDuringSuccessorBlackout() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);
        _simulateDissolutionStarted(NETUID1);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 0);
        assertEq(tao, 5 * TAO);
    }

    function test_PreviewUnwrapUnknownTokenId() public view {
        (uint256 alpha, uint256 tao) = lens.previewUnwrap(0xDEADBEEF, 1000);
        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_PreviewUnwrapZeroShares() public view {
        (uint256 alpha, uint256 tao) = lens.previewUnwrap(1, 0);
        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_PreviewUnwrap_AccountsForRotatedOutStake() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _plantVaultStakes(NETUID1, 0, 0, 30 * ALPHA);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(actualAlpha, 30 * ALPHA, "unwrap reclaims rotated-out stake and pays the full deposit");
        assertEq(previewAlpha, actualAlpha, "preview must match what unwrap actually pays");
    }

    function test_PreviewUnwrapSurvivesFullRegistryRotationWithoutRebalance() public {
        _setValidators(NETUID1, _hotkeys(hotkey4), _weights(VaultMath.BPS_BASE));
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 * ALPHA, hotkey4);
        _wrapHotkey(alice, NETUID1, hotkey4);

        _setValidators(NETUID1, _hotkeys(hotkey1, hotkey2, hotkey3), _weights(3334, 3333, 3333));

        uint256 shares = vault.balanceOf(alice, TOKEN1);
        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(actualAlpha, 30 * ALPHA, "unwrap reclaims stake from the rotated-out validator");
        assertEq(previewAlpha, actualAlpha, "preview matches what unwrap pays after registry rotation");
    }

    function test_PreviewUnwrapReflectsFreshEmissions() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _simulateEmissions(NETUID1, 6 * ALPHA);

        (uint256 previewAlpha,) = lens.previewUnwrap(TOKEN1, shares);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        uint256 actualAlpha = _userStakeAcrossHotkeys(alice, NETUID1);
        // 3e19 * (3.6e10 + 1) / (3e19 + 1e9), floored.
        assertEq(actualAlpha, 36 * ALPHA - 1, "unwrap pays deposit + accrued emissions");
        assertEq(previewAlpha, actualAlpha, "preview reflects fresh on-chain balances incl. emissions");
    }

    function test_PreviewUnwrapReturnsZeroWhenVaultDrained() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _plantVaultStakes(NETUID1, 0, 0, 0);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);

        assertEq(alpha, 0);
        assertEq(tao, 0);
    }

    function test_RevertWhen_SharePriceForReRegisteredSubnetOldTokenId() public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);

        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(TOKEN1);
    }

    function test_RevertWhen_SharePriceOfADissolvedTokenEvenAfterAForceSend() public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(TOKEN1);

        _donateToClone(clone, 100 * TAO);
        vm.expectRevert(SubnetDissolved.selector);
        lens.sharePrice(TOKEN1);
    }

    function test_RevertWhen_PreviewWrapForDissolvedTokenId() public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        vm.expectRevert(SubnetDissolved.selector);
        lens.previewWrap(TOKEN1, 10 * ALPHA);
    }

    function test_RevertWhen_PreviewWrapForReRegisteredSubnetOldTokenId() public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);

        vm.expectRevert(SubnetDissolved.selector);
        lens.previewWrap(TOKEN1, 10 * ALPHA);
    }

    function test_ForceSendBeforeDissolvedUnwrapIsDonationToHolders() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        _donateToClone(clone, 1 * TAO);

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(alice.balance - aliceBalBefore, 6 * TAO, "sole holder captures legit refund + attacker's donation");
    }

    function test_ForceSendBetweenPartialDissolvedUnwraps_BenefitsLaterUnwraps() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 60 * ALPHA);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 40 * ALPHA);
        address clone = vault.subnetClone(TOKEN1);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 5 * TAO);
        _simulateDissolutionCompleted(NETUID1);

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBalBefore, 3 * TAO, "alice gets 60% of the legit pot");

        _donateToClone(clone, 1 * TAO);

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);
        assertEq(bob.balance - bobBalBefore, 3 * TAO, "bob gets the other 2 TAO plus the donation");
    }

    function test_RevertWhen_PreviewUnwrapBlackoutOfCurrentRegistration() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        lens.previewUnwrap(TOKEN1, shares);
    }

    function test_RevertWhen_SharePriceBlackoutOfCurrentRegistration() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        lens.sharePrice(TOKEN1);
    }

    function test_RevertWhen_PreviewWrapBlackoutOfCurrentRegistration() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        _simulateDissolutionStarted(NETUID1);

        vm.expectRevert(SubnetInDissolutionBlackoutPeriod.selector);
        lens.previewWrap(TOKEN1, 10 * ALPHA);
    }

    function test_PreviewUnwrap_QuotesNothingForADissolvedPositionWithoutARefund() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        _simulateDissolutionStarted(NETUID1);
        _simulateTaoAwardedOnDissolution(TOKEN1, 0);
        _simulateDissolutionCompleted(NETUID1);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(alpha, 0, "no alpha remains after dissolution");
        assertEq(tao, 0, "no refund quotes zero");
    }

    function test_ForceSendDoesNotAffectAlphaPayout() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        _donateToClone(vault.subnetClone(TOKEN1), 10 * TAO);

        (uint256 alpha, uint256 tao) = lens.previewUnwrap(TOKEN1, shares);
        assertEq(tao, 0);
        assertEq(alpha, 10 * ALPHA);
    }

    function test_RebalanceRecycledSubnetSilentNoop() public {
        _depositAndWrap(alice, NETUID1, 10 * ALPHA);

        address oldClone = vault.subnetClone(TOKEN1);

        _reregisterSubnet(NETUID1);
        uint256 newTokenId = vault.currentTokenId(NETUID1);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0);
        assertEq(vault.subnetClone(newTokenId), address(0));
        assertEq(lens.totalStake(newTokenId), 0);
        assertEq(_lastSeen(newTokenId).length, 0);
        assertEq(_userStakeAcrossHotkeys(oldClone, NETUID1), 10 * ALPHA, "the old generation's alpha stays put");
    }

    function test_ReplacedGenerationRefundsTaoWhileTheNewGenerationPaysAlpha() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 100 * ALPHA);

        _simulateNewNetworkRegistered(TOKEN1, 5 * TAO);

        uint256 bobShares = _depositAndWrap(bob, NETUID1, 20 * ALPHA);
        uint256 newTokenId = vault.currentTokenId(NETUID1);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        assertEq(alice.balance - aliceBefore, 5 * TAO);

        vm.prank(bob);
        vault.unwrap(newTokenId, bobShares, _toSubstrate(bob), 0);
        assertEq(_userStakeAcrossHotkeys(bob, NETUID1), 20 * ALPHA);
    }

    function test_RevertWhen_WrapChosenOutOfSet() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 * ALPHA, hotkey4);
        vm.prank(alice);
        vm.expectRevert(ChosenHotkeyNotInSet.selector);
        vault.wrap(NETUID1, hotkey4, 0);
    }

    function test_WrapCount1ChosenIsValidatorNoMoves() public {
        _registerSubnet(99, hotkey4);

        _simulateAlphaDepositHotkey(alice, 99, 10 * ALPHA, hotkey4);
        _wrapHotkey(alice, 99, hotkey4);

        assertEq(_getVaultStake(hotkey4, 99), 10 * ALPHA);
        assertEq(_getVaultStake(hotkey1, 99), 0);
        assertEq(_getVaultStake(hotkey2, 99), 0);
    }

    function test_RevertWhen_WrapZeroChosenHotkey() public {
        vm.prank(alice);
        vm.expectRevert(ZeroHotkey.selector);
        vault.wrap(NETUID1, bytes32(0), 0);
    }

    function test_RevertWhen_WrapWhenChosenHasZeroStakeEvenIfOtherHotkeyFunded() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey1);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.wrap(NETUID1, hotkey2, 0);
    }

    function test_RevertWhen_WrapMintsBelowMinSharesOut() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 * ALPHA, hotkey1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 3e19));
        vault.wrap(NETUID1, hotkey1, 3e19 + 1);
    }

    function test_RevertWhen_BackingGrowsBetweenQuoteAndWrap() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateAlphaDepositHotkey(bob, NETUID1, 30 * ALPHA, hotkey1);
        // 3e10 * (3e19 + 1e9) / (3e10 + 1) = 3e19 exactly.
        assertEq(lens.previewWrap(TOKEN1, 30 * ALPHA), 3e19);

        _simulateEmissions(NETUID1, 30 * ALPHA);

        // 3e10 * (3e19 + 1e9) / (6e10 + 1), floored: the appreciation halves the rate.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 15_000_000_000_249_999_999));
        vault.wrap(NETUID1, hotkey1, 3e19);
    }

    function testFuzz_WrapMintsTheQuoteUnderAnyBoundAtOrBelowIt(uint256 depositAlpha, uint256 boundBps) public {
        depositAlpha = bound(depositAlpha, ALPHA_FLOOR, MAX_SUBNET_ALPHA);
        boundBps = bound(boundBps, 0, VaultMath.BPS_BASE);
        _simulateAlphaDepositHotkey(alice, NETUID1, depositAlpha, hotkey1);
        uint256 quoted = lens.previewWrap(TOKEN1, depositAlpha);
        uint256 minSharesOut = (quoted * boundBps) / VaultMath.BPS_BASE;

        vm.prank(alice);
        vault.wrap(NETUID1, hotkey1, minSharesOut);

        assertEq(vault.balanceOf(alice, TOKEN1), quoted, "the quote is what the vault mints");
    }

    function testFuzz_RevertWhen_MinSharesOutExceedsTheQuote(uint256 depositAlpha, uint256 excess) public {
        depositAlpha = bound(depositAlpha, ALPHA_FLOOR, MAX_SUBNET_ALPHA);
        _simulateAlphaDepositHotkey(alice, NETUID1, depositAlpha, hotkey1);
        uint256 quoted = lens.previewWrap(TOKEN1, depositAlpha);
        excess = bound(excess, 1, type(uint256).max - quoted);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, quoted));
        vault.wrap(NETUID1, hotkey1, quoted + excess);
    }

    function test_WrapDerivesMailboxColdkeyFromUserClone() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 10 * ALPHA, hotkey1);
        _simulateAlphaDepositHotkey(bob, NETUID1, 5 * ALPHA, hotkey1);

        address aliceClone = vault.getDepositAddress(alice, NETUID1);
        address bobClone = vault.getDepositAddress(bob, NETUID1);

        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(aliceClone), NETUID1), 0);
        assertEq(MockStaking(STAKING_PRECOMPILE).getStake(hotkey1, _toSubstrate(bobClone), NETUID1), 5 * ALPHA);
        assertEq(lens.totalStake(TOKEN1), 10 * ALPHA);
    }

    function test_WrapPreservesPriorBalances() public {
        _simulateAlphaDepositHotkey(alice, NETUID1, 30 * ALPHA, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);
        assertEq(_getVaultStake(hotkey1, NETUID1), 10_002_000_000);
        assertEq(_getVaultStake(hotkey2, NETUID1), 9_999_000_000);
        assertEq(_getVaultStake(hotkey3, NETUID1), 9_999_000_000);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 * ALPHA, hotkey1);
        _wrapHotkey(bob, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), 20_004_000_000);
        assertEq(_getVaultStake(hotkey2, NETUID1), 19_998_000_000);
        assertEq(_getVaultStake(hotkey3, NETUID1), 19_998_000_000);
        assertEq(lens.totalStake(TOKEN1), 60 * ALPHA);
    }

    function _setNetuid1Set(bytes32 a, bytes32 b, bytes32 c) private {
        _setValidators(NETUID1, _hotkeys(a, b, c), _weights(NETUID1_BPS_HK1, NETUID1_BPS_HK2, NETUID1_BPS_HK3));
    }

    function test_LastSeenSnapshot_InitializedOnFirstWrap() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32[] memory lastSeen = _lastSeen(TOKEN1);
        assertEq(lastSeen[0], hotkey1);
        assertEq(lastSeen[1], hotkey2);
        assertEq(lastSeen[2], hotkey3);
    }

    function test_RotationSweptOnRebalance() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out slot must be drained");
        assertEq(_countRebalancedLogs(logs), 1, "silent consolidation; only the post-consolidation alignment logs");
        assertEq(_getVaultStake(hotkey4, NETUID1), 9_999_000_000, "the new key takes the dropped key's weight");

        bytes32[] memory lastSeen = _lastSeen(TOKEN1);
        assertEq(lastSeen.length, 3);
        assertEq(lastSeen[2], hotkey4, "cleared rotated-out slot follows the current set");
    }

    function test_RotationSweptOnNextWrap() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 * ALPHA, hotkey1);
        _wrapHotkey(bob, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out stake consolidated before second deposit");
        assertEq(lens.totalStake(TOKEN1), 60 * ALPHA);
        assertEq(vault.balanceOf(bob, TOKEN1), 3e19, "the consolidated stake still prices bob's deposit");
    }

    function test_RotationSweptOnUnwrap() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        uint256 received = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(received, 30 * ALPHA, "user must receive full deposit including rotated-out stake");
        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out stake drained as part of unwrap");
    }

    function test_RotationMultipleBacklog_ConsolidatesAllRotatedOutStake() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);
        // hotkey3 returns before any vault call, so only hotkey2 is dropped.
        _setNetuid1Set(hotkey1, hotkey4, hotkey3);

        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey2, NETUID1), 0, "hotkey2 rotated-out stake consolidated");
        assertEq(_getVaultStake(hotkey3, NETUID1), 9_999_000_000, "hotkey3 keeps its slice - back in current set");
        assertEq(_getVaultStake(hotkey4, NETUID1), 9_999_000_000, "hotkey4 takes hotkey2's slice");
    }

    function test_RotationNoChangeIsNoOp() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        vm.recordLogs();
        vault.rebalance(NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countRebalancedLogs(logs), 0, "no-op rebalance emits nothing");
        assertEq(_getVaultStake(hotkey3, NETUID1), 9_999_000_000);
    }

    function test_UnwrapSyncsEmissions() public {
        uint256 shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _simulateEmissions(NETUID1, 5 * ALPHA);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        // 3e19 * (3.5e10 + 1) / (3e19 + 1e9), floored.
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 35 * ALPHA - 1, "sole holder receives deposit + emissions");
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 1, "only the rounding RAO stays behind");
    }

    function test_EmissionsShareEquallyAcrossHolders() public {
        uint256 aliceShares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        uint256 bobShares = _depositAndWrap(bob, NETUID1, 30 * ALPHA);

        _simulateEmissions(NETUID1, 20 * ALPHA);

        vm.prank(alice);
        vault.unwrap(TOKEN1, aliceShares, _toSubstrate(alice), 0);
        // 3e19 * (8e10 + 1) / (6e19 + 1e9), floored.
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 40 * ALPHA - 1, "alice gets her 30 + half of 20 emissions");

        vm.prank(bob);
        vault.unwrap(TOKEN1, bobShares, _toSubstrate(bob), 0);
        // 3e19 * (4e10 + 2) / (3e19 + 1e9), floored: alice's rounding RAO goes to bob.
        assertEq(_userStakeAcrossHotkeys(bob, NETUID1), 40 * ALPHA, "bob gets his 30 + half of 20 emissions");
    }

    function test_PartialUnwrapAccountsForEmissions() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _simulateEmissions(NETUID1, 10 * ALPHA);

        vm.prank(alice);
        vault.unwrap(TOKEN1, 15e18, _toSubstrate(alice), 0);

        // 1.5e19 * (4e10 + 1) / (3e19 + 1e9), floored.
        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), 20 * ALPHA - 1, "alice gets half of 40");
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 20 * ALPHA + 1, "the remaining shares keep the other half");
    }

    function test_TotalStake_ReflectsEmissionsWithoutSync() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        assertEq(lens.sharePrice(TOKEN1), 1e9);

        _simulateEmissions(NETUID1, 5 * ALPHA);

        assertEq(lens.totalStake(TOKEN1), 35 * ALPHA, "totalStake includes the 5-alpha emission");
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1), 35 * ALPHA, "totalStake tracks live stake");
        // 1e18 * (3.5e10 + 1) / (3e19 + 1e9), floored.
        assertEq(lens.sharePrice(TOKEN1), 1_166_666_666, "sharePrice rises with emissions");
    }

    function test_Rebalance_SingleValidatorSet() public {
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(VaultMath.BPS_BASE));

        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _simulateEmissions(NETUID1, 4 * ALPHA);
        vault.rebalance(NETUID1);

        assertEq(lens.totalStake(TOKEN1), 34 * ALPHA, "single-validator stake stays whole and live");
    }

    function test_WrapRebalancesPreSkewedBalances() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _simulateEmissions(NETUID1, 40 * ALPHA);

        _simulateAlphaDepositHotkey(bob, NETUID1, 30 * ALPHA, hotkey1);
        _wrapHotkey(bob, NETUID1, hotkey1);

        assertEq(lens.totalStake(TOKEN1), 100 * ALPHA, "totalStake synced to on-chain total");
        assertEq(_getVaultStake(hotkey1, NETUID1), 33_340_000_000);
        assertEq(_getVaultStake(hotkey2, NETUID1), 33_330_000_000);
        assertEq(_getVaultStake(hotkey3, NETUID1), 33_330_000_000);
    }

    function test_WrapAutoRebalancesTwoValidatorSet() public {
        _simulateAlphaDepositHotkey(alice, NETUID2, 100 * ALPHA, hotkey2);
        _wrapHotkey(alice, NETUID2, hotkey2);

        assertEq(lens.totalStake(TOKEN2), 100 * ALPHA, "totalStake synced");
        assertEq(_getVaultStake(hotkey2, NETUID2), 60 * ALPHA);
        assertEq(_getVaultStake(hotkey1, NETUID2), 40 * ALPHA);
    }

    function testFuzz_WrapUnwrapRoundTripPreservesAlpha(uint256 d) public {
        d = bound(d, ALPHA_FLOOR, MAX_SUBNET_ALPHA);

        uint256 shares = _depositAndWrap(alice, NETUID1, d);

        vm.prank(alice);
        vault.unwrap(TOKEN1, shares, _toSubstrate(alice), 0);

        assertEq(_userStakeAcrossHotkeys(alice, NETUID1), d, "round-trip preserves alpha exactly");
    }

    function testFuzz_RebalanceIdempotent(uint256 b1, uint256 b2, uint256 b3) public {
        b1 = bound(b1, 0, MAX_SUBNET_ALPHA / 3);
        b2 = bound(b2, 0, MAX_SUBNET_ALPHA / 3);
        b3 = bound(b3, 0, MAX_SUBNET_ALPHA / 3);

        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _plantVaultStakes(NETUID1, b1, b2, b3);

        vault.rebalance(NETUID1);
        uint256 b1After = _getVaultStake(hotkey1, NETUID1);
        uint256 b2After = _getVaultStake(hotkey2, NETUID1);
        uint256 b3After = _getVaultStake(hotkey3, NETUID1);

        vm.recordLogs();
        vault.rebalance(NETUID1);

        assertEq(_getVaultStake(hotkey1, NETUID1), b1After, "hotkey1 unchanged on second rebalance");
        assertEq(_getVaultStake(hotkey2, NETUID1), b2After, "hotkey2 unchanged on second rebalance");
        assertEq(_getVaultStake(hotkey3, NETUID1), b3After, "hotkey3 unchanged on second rebalance");
        assertEq(_countRebalancedLogs(vm.getRecordedLogs()), 0, "no Rebalanced events on second call");
    }

    /// @dev The planted layout keeps the deposit's total, so supply stays d * 1e9 on stake d and a burn of
    ///      s shares is worth exactly floor(s / 1e9) RAO.
    function testFuzz_UnwrapConservesAlpha(uint256 b1, uint256 b2, uint256 b3, uint256 burnPct) public {
        // 2 alpha per slot keeps a 1% burn of the smallest total above the 0.04-alpha floor.
        b1 = bound(b1, 2 * ALPHA, MAX_SUBNET_ALPHA / 3);
        b2 = bound(b2, 2 * ALPHA, MAX_SUBNET_ALPHA / 3);
        b3 = bound(b3, 2 * ALPHA, MAX_SUBNET_ALPHA / 3);
        burnPct = bound(burnPct, 1, 99);

        uint256 d = b1 + b2 + b3;
        _simulateAlphaDepositHotkey(alice, NETUID1, d, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        _plantVaultStakes(NETUID1, b1, b2, b3);

        vm.prank(alice);
        vault.unwrap(TOKEN1, d * 1e9 * burnPct / 100, _toSubstrate(alice), 0);

        uint256 userReceived = _userStakeAcrossHotkeys(alice, NETUID1);
        assertEq(userReceived, d * burnPct / 100, "delivers exactly the pro-rata assets");
        assertEq(_totalVaultStakeAcrossHotkeys(NETUID1) + userReceived, d, "unwrap conserves total alpha");
    }

    function testFuzz_RevertWhen_UnwrapPaysBelowTheFloor(uint256 burnShares) public {
        _depositAndWrap(alice, NETUID1, 100 * ALPHA);
        // 1e20 shares on 1e11 RAO: a burn of s shares is worth floor(s / 1e9) RAO, from 1 RAO to just below 0.04 alpha.
        burnShares = bound(burnShares, 1e9, ALPHA_FLOOR * 1e9 - 1);

        vm.prank(alice);
        vm.expectRevert(WithdrawTooSmall.selector);
        vault.unwrap(TOKEN1, burnShares, _toSubstrate(alice), 0);
    }

    /// @dev k * 10,000 + 7 RAO: the two weighted slices floor 7 * 3334 and 7 * 3333 bps to 2 RAO each, and
    ///      the last slot takes the remaining 3.
    function testFuzz_WrapLandsExactlyOnTargets(uint256 k) public {
        // 12,002 * 3333 RAO is the smallest slice that clears the 0.04-alpha floor.
        k = bound(k, 12_002, MAX_SUBNET_ALPHA / 10_000);
        uint256 d = k * 10_000 + 7;

        _simulateAlphaDepositHotkey(alice, NETUID1, d, hotkey1);
        _wrapHotkey(alice, NETUID1, hotkey1);

        assertEq(_getVaultStake(hotkey1, NETUID1), k * 3334 + 2, "hotkey1 hits weight target exactly");
        assertEq(_getVaultStake(hotkey2, NETUID1), k * 3333 + 2, "hotkey2 hits weight target exactly");
        assertEq(_getVaultStake(hotkey3, NETUID1), k * 3333 + 3, "the last slot takes the remainder");
        assertEq(lens.totalStake(TOKEN1), d, "totalStake synced to deposit amount");
    }

    function testFuzz_RotatedOutStakeReclaimedAcrossRotation(uint256 b1, uint256 b2, uint256 b3) public {
        // hotkey1 stays above the 0.04-alpha floor so the roller can start there while hotkey3 fuzzes down to zero.
        b1 = bound(b1, ALPHA_FLOOR, MAX_SUBNET_ALPHA / 3);
        b2 = bound(b2, 0, MAX_SUBNET_ALPHA / 3);
        b3 = bound(b3, 0, MAX_SUBNET_ALPHA / 3);

        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _plantVaultStakes(NETUID1, b1, b2, b3);

        _setNetuid1Set(hotkey1, hotkey2, hotkey4);

        vault.rebalance(NETUID1);

        uint256 a1 = _getVaultStake(hotkey1, NETUID1);
        uint256 a2 = _getVaultStake(hotkey2, NETUID1);
        uint256 a4 = _getVaultStake(hotkey4, NETUID1);

        assertEq(_getVaultStake(hotkey3, NETUID1), 0, "rotated-out stake fully consolidated by the roller");
        assertEq(a1 + a2 + a4, b1 + b2 + b3, "active set holds the whole post-roll total");
        assertEq(lens.totalStake(TOKEN1), b1 + b2 + b3, "totalStake counts the consolidated backing");

        bytes32[] memory seen = _lastSeen(TOKEN1);
        assertEq(seen[0], hotkey1);
        assertEq(seen[1], hotkey2);
        assertEq(seen[2], hotkey4, "remembered set refreshed to the current set");
    }

    /// @dev A k * 10,000 + 7 RAO total targets k * 3334 + 2, k * 3333 + 2 and, as the remainder, k * 3333 + 3.
    function testFuzz_RebalanceConvergesWithinBoundToFloorFixpoint(uint256 k1, uint256 k2, uint256 k3) public {
        k1 = bound(k1, 0, MAX_SUBNET_ALPHA / 30_000);
        k2 = bound(k2, 0, MAX_SUBNET_ALPHA / 30_000);
        k3 = bound(k3, 0, MAX_SUBNET_ALPHA / 30_000);

        _depositAndWrap(alice, NETUID1, 30 * ALPHA);

        _plantVaultStakes(NETUID1, k1 * 10_000 + 7, k2 * 10_000, k3 * 10_000);

        uint256 k = k1 + k2 + k3;
        uint256 preTotal = k * 10_000 + 7;

        vm.recordLogs();
        vault.rebalance(NETUID1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256[3] memory balances =
            [_getVaultStake(hotkey1, NETUID1), _getVaultStake(hotkey2, NETUID1), _getVaultStake(hotkey3, NETUID1)];
        uint256[3] memory targets = [k * 3334 + 2, k * 3333 + 2, k * 3333 + 3];

        assertEq(balances[0] + balances[1] + balances[2], preTotal, "rebalance conserves total alpha");
        assertEq(lens.totalStake(TOKEN1), preTotal, "totalStake synced to on-chain total");
        assertLe(_countRebalancedLogs(logs), 2, "rebalance loop bounded by N-1 iterations");

        uint256 maxOver;
        uint256 maxUnder;
        for (uint256 i; i < 3; ++i) {
            if (balances[i] > targets[i] && balances[i] - targets[i] > maxOver) maxOver = balances[i] - targets[i];
            if (targets[i] > balances[i] && targets[i] - balances[i] > maxUnder) maxUnder = targets[i] - balances[i];
        }

        uint256 minMatchable = maxOver < maxUnder ? maxOver : maxUnder;
        assertLt(minMatchable, ALPHA_FLOOR, "rebalance reaches floor-bounded fixpoint");
    }
}
