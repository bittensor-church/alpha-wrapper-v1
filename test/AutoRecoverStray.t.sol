// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { NothingToRecover } from "src/VaultErrors.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { MAX_VALIDATORS } from "src/interfaces/IValidatorRegistry.sol";
import { MockStaking } from "./mocks/MockStaking.sol";

contract AutoRecoverStrayTest is AlphaVaultTestBase {
    uint256 private constant FIRST_SLOT = 10_002_000_000;
    uint256 private constant OTHER_TWO_SLOTS = 19_998_000_000;
    uint256 private constant SETUP_NONCE = 1;

    function _strangerMovesTheFirstSlot() private returns (uint256 shares) {
        shares = _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        MockStaking(STAKING_PRECOMPILE).setHotkeyDeleted(hotkey1, true);
    }

    function test_AutoRecoverStray_ParksAnEdgelessMoveWithoutASource() public {
        _strangerMovesTheFirstSlot();
        vault.syncBacking(TOKEN1);
        uint256 deadline = lens.writeOffDeadline(TOKEN1);
        assertEq(lens.missingStake(TOKEN1), FIRST_SLOT, "the moved slot is missing after declaration");
        bytes32 parking = vault.parkingHotkey();

        vm.expectEmit(true, true, false, true, address(vault));
        emit BackingRecovered(TOKEN1, parking, FIRST_SLOT);
        vm.prank(bob);
        vault.autoRecoverStray(TOKEN1);

        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "the staking list led to the moved pile");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0);
        assertEq(lens.missingStake(TOKEN1), 0);
        assertEq(lens.writeOffDeadline(TOKEN1), deadline, "collection keeps the deadline");

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingParked(TOKEN1, 30 * ALPHA, SETUP_NONCE);
        vault.syncBacking(TOKEN1);
        assertTrue(vault.awaitingAttestation(TOKEN1));
        assertTrue(lens.isBackingIntact(TOKEN1));
    }

    function test_AutoRecoverStray_FollowsATwoHopTrail() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        bytes32 tip = _buildSwapTrail(NETUID1, hotkey1, 2);
        vault.syncBacking(TOKEN1);

        vault.autoRecoverStray(TOKEN1);
        vault.syncBacking(TOKEN1);

        assertEq(_getVaultStake(tip, NETUID1), 0, "the trail's tip is empty");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
        assertEq(lens.writeOffDeadline(TOKEN1), 0);
    }

    function test_AutoRecoverStray_CollectsSeveralDestinationsInOneCall() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _simulateOffVaultSwap(NETUID1, hotkey2, hotkey5);
        _simulateOffVaultSwap(NETUID1, hotkey3, keccak256("third destination"));
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 0, "nothing was located at declaration");

        vault.autoRecoverStray(TOKEN1);

        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "every destination was collected");
        assertEq(lens.missingStake(TOKEN1), 0);
    }

    function test_AutoRecoverStray_CollectsAPagePerCall() public {
        uint256 netuid = 9;
        _setRegBlock(netuid, 400);
        bytes32[] memory hotkeys = _setValidatorCount(netuid, MAX_VALIDATORS);
        _simulateAlphaDeposit(alice, netuid, MAX_VALIDATORS * ALPHA);
        _wrapHotkey(alice, netuid, hotkeys[0]);
        uint256 tokenId = vault.currentTokenId(netuid);
        for (uint256 i; i < hotkeys.length; ++i) {
            _simulateOffVaultSwap(netuid, hotkeys[i], keccak256(abi.encode("destination", i)));
        }
        vault.syncBacking(tokenId);

        vault.autoRecoverStray(tokenId);
        assertEq(_parkedStake(netuid), 8 * ALPHA, "one page of eight strays per call");
        vault.autoRecoverStray(tokenId);
        assertEq(_parkedStake(netuid), MAX_VALIDATORS * ALPHA, "the next call takes the rest");
        vm.expectRevert(NothingToRecover.selector);
        vault.autoRecoverStray(tokenId);

        vault.syncBacking(tokenId);
        assertEq(lens.totalStake(tokenId), MAX_VALIDATORS * ALPHA);
        assertEq(lens.writeOffDeadline(tokenId), 0);
    }

    function testFuzz_AutoRecoverStray_FindsTheMovedPileAtAnyListPosition(
        uint256 entriesBefore,
        uint256 entriesAfter,
        uint256 amount
    ) public {
        entriesBefore = bound(entriesBefore, 3, 120);
        entriesAfter = bound(entriesAfter, 0, 120);
        amount = bound(amount, ALPHA, 1_000 * ALPHA);
        _depositAndWrap(alice, NETUID1, amount);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        _fillListTo(coldkey, entriesBefore);
        _simulateOffVaultSwap(NETUID1, hotkey1, hotkey4);
        _fillListTo(coldkey, entriesBefore + 1 + entriesAfter);
        vault.syncBacking(TOKEN1);

        vault.autoRecoverStray(TOKEN1);

        assertEq(_parkedStake(NETUID1), amount, "the moved pile was found wherever the list holds it");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0);
    }

    function test_AutoRecoverStray_AnnexesAStrangersPileUnderAListedHotkey() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _keepListed(NETUID1, hotkey4);
        _strangerReturns(NETUID1, hotkey4, 5 * ALPHA);

        vault.autoRecoverStray(TOKEN1);

        assertEq(lens.totalStake(TOKEN1), 35 * ALPHA, "the pile joined live backing");
        assertEq(_getVaultStake(hotkey4, NETUID1), 0);
        assertTrue(lens.isBackingIntact(TOKEN1));
    }

    function test_AutoRecoverStray_AfterAWriteOff_JoinsTheParkedPosition() public {
        _strangerMovesTheFirstSlot();
        _runOutRecoveryWindow(TOKEN1);
        assertEq(_parkedStake(NETUID1), OTHER_TWO_SLOTS, "the write-off parked what the sync located");

        vault.autoRecoverStray(TOKEN1);

        assertEq(_parkedStake(NETUID1), 30 * ALPHA, "the find joins the parked position");
        assertEq(lens.totalStake(TOKEN1), 30 * ALPHA);
    }

    function test_AutoRecoverStray_LeavesReturnsUnderRecordedHotkeysToSync() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _keepListed(NETUID1, hotkey1);
        uint256 swept = _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);
        _strangerReturns(NETUID1, hotkey1, swept);

        vm.expectRevert(NothingToRecover.selector);
        vault.autoRecoverStray(TOKEN1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit BackingShortfallCleared(TOKEN1);
        vault.syncBacking(TOKEN1);
    }

    function test_RevertWhen_AutoRecoverStrayFindsNothing() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        vm.expectRevert(NothingToRecover.selector);
        vault.autoRecoverStray(TOKEN1);

        _sweepDuringCrash(NETUID1, hotkey1);
        vault.syncBacking(TOKEN1);
        vm.expectRevert(NothingToRecover.selector);
        vault.autoRecoverStray(TOKEN1);
    }

    function test_RevertWhen_AutoRecoverStrayFindsOnlyDustWithNothingToCarryIt() public {
        _depositAndWrap(alice, NETUID1, 30 * ALPHA);
        _keepListed(NETUID1, hotkey4);
        _sweepDuringCrash(NETUID1, hotkey1);
        _sweepDuringCrash(NETUID1, hotkey2);
        _sweepDuringCrash(NETUID1, hotkey3);
        vault.syncBacking(TOKEN1);
        assertEq(_parkedStake(NETUID1), 0);
        _strangerReturns(NETUID1, hotkey4, ALPHA_FLOOR / 2);

        vm.expectRevert(NothingToRecover.selector);
        vault.autoRecoverStray(TOKEN1);
        assertEq(_getVaultStake(hotkey4, NETUID1), ALPHA_FLOOR / 2, "the dust stays where it is");
    }

    function test_RevertWhen_AutoRecoveringWithoutAPosition() public {
        vm.expectRevert(NothingToRecover.selector);
        vault.autoRecoverStray(TOKEN1);
    }

    function test_RevertWhen_AutoRecoveringARetiredTokenId() public {
        _strangerMovesTheFirstSlot();
        _reregisterSubnet(NETUID1);
        vm.expectRevert(NothingToRecover.selector);
        vault.autoRecoverStray(TOKEN1);
    }

    function test_RecoverStray_StillCollectsASourceByName() public {
        _strangerMovesTheFirstSlot();
        vault.syncBacking(TOKEN1);

        vault.recoverStray(TOKEN1, hotkey4);

        assertEq(_parkedStake(NETUID1), 30 * ALPHA);
    }
}
