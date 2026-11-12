// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    Attempt,
    BackingCampaignHandler,
    BackingCampaignHarness,
    recoverErrors,
    replaceErrors
} from "./helpers/BackingCampaign.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";
import { CHAIN_MAX_STAKING_HOTKEYS, MockStaking } from "./mocks/MockStaking.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";

contract BackingHandler is BackingCampaignHandler {
    uint256 public strayAnnexations;
    uint256 public strayCollections;
    uint256 public replacements;

    constructor(
        AlphaVault _vault,
        BackingCampaignSetup _harness,
        uint256 _tokenId,
        uint256 _netuid,
        address[] memory _actors,
        bytes32[] memory _seedHotkeys
    ) BackingCampaignHandler(_vault, _harness, _tokenId, _netuid, _actors, _seedHotkeys) { }

    /// @dev Strangers have pinned the clone's list to its last own entry; anyone may then replace the clone. A
    ///      refused replacement lifts the pins again so the rest of the campaign keeps its own refusal rules.
    function replaceClone(uint256 uidSeed) external {
        address previous = vault.subnetClone(tokenId);
        bytes32 previousColdkey = harness.cloneColdkey();
        uint256 cloneTao = previous.balance;
        uint256 holdings = harness.chainHoldings();
        _backing().pinStakingList(true);
        try vault.replaceClone(tokenId, keccak256(abi.encode("successor", replacements, uidSeed))) {
            ++replacements;
            assertEq(previous.balance, 0, "the old clone keeps no TAO");
            assertEq(vault.subnetClone(tokenId).balance, cloneTao, "the new clone receives all the TAO");
            uint256 moved = harness.assertRecordMatchesChain();
            assertEq(harness.chainHoldings(), moved, "the new clone holds exactly the recorded backing");
            assertEq(harness.stakeOf(previousColdkey) + moved, holdings, "the replacement conserves the alpha");
            _backing().assertMovedPilesLeft(previousColdkey);
        } catch (bytes memory reason) {
            _backing().pinStakingList(false);
            _requireJustifiedRevert(reason, replaceErrors(), Attempt(0, 0, 0, bytes32(0), false));
        }
    }

    function swapHotkey(uint256 fromSeed, uint256 toSeed) external {
        bytes32 from = touchedHotkeys[bound(fromSeed, 0, touchedHotkeys.length - 1)];
        bytes32 to = keccak256(abi.encode("swapped", toSeed));
        if (from == to) return;
        _remember(to);
        _backing().simulateSwap(from, to);
    }

    function swapWithoutAnEdge(uint256 fromSeed, uint256 toSeed) external {
        bytes32 from = touchedHotkeys[bound(fromSeed, 0, touchedHotkeys.length - 1)];
        bytes32 to = keccak256(abi.encode("stray", toSeed));
        if (from == to) return;
        _remember(to);
        _backing().simulateSilentMove(from, to);
    }

    function strandInTwoPiles(uint256 fromSeed, uint256 toSeed) external {
        bytes32 from = touchedHotkeys[bound(fromSeed, 0, touchedHotkeys.length - 1)];
        if (!_backing().strandable(from)) return;
        bytes32 first = keccak256(abi.encode("half", toSeed, uint256(0)));
        bytes32 second = keccak256(abi.encode("half", toSeed, uint256(1)));
        _remember(first);
        _remember(second);
        _backing().simulateSweepReturnedInTwoPiles(from, first, second);
    }

    function sourceFor(uint256 sourceSeed) public view returns (bytes32) {
        return
            touchedHotkeys[bound(uint256(keccak256(abi.encode(sourceSeed, uint256(0)))), 0, touchedHotkeys.length - 1)];
    }

    function recoverStray(uint256 sourceSeed) external {
        _recover(sourceFor(sourceSeed));
    }

    function recoverHeldStray(uint256 sourceSeed) external {
        bytes32[] memory held = _backing().touchedHotkeysHoldingStake(touchedHotkeys);
        if (held.length == 0) return;
        _recover(held[bound(sourceSeed, 0, held.length - 1)]);
    }

    function _recover(bytes32 source) private {
        uint256 slotsBefore = vault.recordedSlots(tokenId).length;
        if (slotsBefore == 0) return;
        (uint256 shortSince,) = vault.recovery(tokenId);
        uint256 owedBefore = harness.trackedBacking();
        uint256 supplyBefore = vault.totalSupply(tokenId);
        uint256 holdings = harness.chainHoldings();
        uint256 parkedBefore = harness.parkedStake();
        uint256 stray = harness.vaultStakeAt(source);
        bytes32[] memory watched = harness.watchedHotkeys();
        uint256[] memory stakesBefore = harness.vaultStakesAt(watched);
        try vault.recoverStray(tokenId, source) {
            assertEq(vault.totalSupply(tokenId), supplyBefore, "recovery changed the supply");
            assertEq(harness.chainHoldings(), holdings, "recovery only moves backing within the clone");
            assertEq(harness.vaultStakeAt(source), 0, "recovery empties the stray");
            if (shortSince == 0) {
                ++strayAnnexations;
                uint256 tracked = harness.assertRecordMatchesChain();
                assertEq(
                    tracked,
                    harness.recordedStakeAmong(watched, stakesBefore) + stray,
                    "an annexation adds exactly the stray to the backing"
                );
                assertGe(
                    tracked + harness.slack() * slotsBefore, owedBefore, "recovery discarded part of the obligation"
                );
            } else {
                ++strayCollections;
                assertEq(harness.trackedBacking(), owedBefore, "collection changed the obligation");
                assertEq(
                    harness.parkedStake(),
                    parkedBefore + stray,
                    "a collection moves exactly the stray onto the parking hotkey"
                );
            }
        } catch (bytes memory reason) {
            _requireJustifiedRevert(reason, recoverErrors(), Attempt(0, 0, 0, source, false));
        }
    }

    function rotateValidators(uint256 seed) external {
        bytes32[] memory set = new bytes32[](bound(seed, 1, 3));
        for (uint256 i; i < set.length; ++i) {
            set[i] = touchedHotkeys[bound(uint256(keccak256(abi.encode(seed, i))), 0, touchedHotkeys.length - 1)];
            for (uint256 j; j < i; ++j) {
                if (set[j] == set[i]) set[i] = keccak256(abi.encode("rotated", seed, i, touchedHotkeys.length));
            }
            _remember(set[i]);
        }
        harness.attest(set);
    }

    function _backing() private view returns (BackingCampaignSetup) {
        return BackingCampaignSetup(address(harness));
    }
}

abstract contract BackingCampaignSetup is BackingCampaignHarness {
    BackingHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](2);
        actors[0] = alice;
        actors[1] = bob;
        _depositAndWrap(alice, NETUID1, 50 * ALPHA);

        attestedHotkeys = _hotkeys(hotkey1, hotkey2, hotkey3);
        bytes32[] memory seeds = _hotkeys(hotkey1, hotkey2, hotkey3);
        handler = new BackingHandler(vault, this, TOKEN1, NETUID1, actors, seeds);
        targetContract(address(handler));
    }

    function _campaign() internal view override returns (BackingCampaignHandler) {
        return handler;
    }

    function assertMovedPilesLeft(bytes32 previousColdkey) external view {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i].tracked == 0) continue;
            assertEq(
                _getStakeForColdkey(slots[i].stakedUnder, previousColdkey, NETUID1),
                0,
                "a moved pile leaves nothing on the old clone"
            );
        }
    }

    function touchedHotkeysHoldingStake(bytes32[] memory hotkeys) external view returns (bytes32[] memory held) {
        uint256 count;
        held = new bytes32[](hotkeys.length);
        for (uint256 i; i < hotkeys.length; ++i) {
            if (_getVaultStake(hotkeys[i], NETUID1) != 0) held[count++] = hotkeys[i];
        }
        assembly {
            mstore(held, count)
        }
    }

    function simulateSwap(bytes32 from, bytes32 to) external {
        _simulateFollowedSwap(NETUID1, from, to);
    }

    function pinStakingList(bool pinned) external {
        MockStaking(STAKING_PRECOMPILE)
            .pinStakingEntries(_subnetColdkey(NETUID1), pinned ? CHAIN_MAX_STAKING_HOTKEYS - 1 : 0);
    }

    function simulateSilentMove(bytes32 from, bytes32 to) external {
        _simulateOffVaultSwap(NETUID1, from, to);
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract BackingInvariantTest is BackingCampaignSetup {
    function invariant_TotalTrackedBackingIsBoundedByCurrentChainHoldings() public view {
        _assertTrackedBackingWithinChainHoldings();
    }

    function invariant_ReportedBackingNeverExceedsWhatTheChainHolds() public view {
        _assertReportedBackingWithinChainHoldings();
    }

    function invariant_NoTwoSlotsAnswerForOneHotkey() public view {
        _assertNoTwoSlotsAnswerForOneHotkey();
    }
}

contract BackingCampaignPathsTest is BackingCampaignSetup {
    function test_ReplayOfEdgelessAndFollowedSwapsBetweenSyncsAndRecoveries_PreservesBackingInvariants() public {
        handler.swapWithoutAnEdge(3920, 702498195375104724870804370661893358612984996200603330987954554);
        _assertSharedInvariants();
        handler.swapWithoutAnEdge(21936, 9555);
        _assertSharedInvariants();
        handler.swapWithoutAnEdge(0, 46484125467125653278869020054723548665048815226470);
        _assertSharedInvariants();
        handler.syncBacking();
        _assertSharedInvariants();
        handler.recoverStray(361656362808158655897425226168322);
        _assertSharedInvariants();
        handler.swapHotkey(395928111782571441, 47594521996258548997527314557814977391483923631630328760470);
        _assertSharedInvariants();
        handler.swapWithoutAnEdge(115792089237316195423570985008687907853269984665640564039457584007913129639932, 2);
        _assertSharedInvariants();
        handler.syncBacking();
        _assertSharedInvariants();
        handler.recoverStray(496832458824593621465406068473474564241632359248770171723107483670860501638);
        _assertSharedInvariants();
        handler.swapHotkey(1000000000000000000, 518);
        _assertSharedInvariants();
        handler.swapHotkey(39284778829218561959962831765498513039391595077, 1);
        _assertSharedInvariants();
        handler.swapHotkey(4668825657844413095552775974875155388807116336350818157329463057335574, 863968505977431908);
        _assertSharedInvariants();
        handler.rotateValidators(25670646866713597079810818809857953515987733532491365243132352747204520724);
        _assertSharedInvariants();
        handler.wrap(4982, 2038218518, 126689249586524825498559537986693588869175255532239560737778380983908754);
        _assertSharedInvariants();
        handler.swapHotkey(
            5022836071830231965563198741131435959745735624404810078992442116285814296610,
            10708288936997174409238467093412100671917613552582
        );
        _assertSharedInvariants();
        handler.swapWithoutAnEdge(2720838758, 2641);
        _assertSharedInvariants();
        handler.swapWithoutAnEdge(2151, 2641);
        _assertSharedInvariants();
        handler.syncBacking();
        _assertSharedInvariants();
        handler.recoverStray(115792089237316195423570985008687907853269984665640564039457584007913129639935);
        _assertSharedInvariants();
    }

    function test_HandlerReachesEverySuccessPath() public {
        handler.wrap(1, 100, 0);
        _assertSharedInvariants();
        assertEq(handler.wraps(), 1, "the deposit wraps into shares");
        handler.unwrap(0, 1e18);
        _assertSharedInvariants();
        handler.unwrapForTao(0, 1e18);
        _assertSharedInvariants();
        assertEq(handler.alphaExits(), 1, "the alpha exit succeeds from a healthy position");
        assertEq(handler.taoExits(), 1, "the TAO exit succeeds from a healthy position");
        uint256 owed = trackedBacking();

        handler.swapWithoutAnEdge(0, 1);
        _assertSharedInvariants();
        assertTrue(lens.isBackingIntact(TOKEN1), "a cut edge resolves on the staking list");
        handler.syncBacking();
        assertEq(
            vault.recordedSlots(TOKEN1)[0].stakedUnder, keccak256(abi.encode("stray", uint256(1))), "and is recorded"
        );

        handler.strandInTwoPiles(3, 1);
        assertEq(vault.recordedSlots(TOKEN1).length, 3, "one slot per attested hotkey before recovery");
        _assertSharedInvariants();
        handler.syncBacking();
        _assertSharedInvariants();
        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectEmit(true, false, false, false);
        emit IAlphaVaultAbi.BackingWrittenOff(TOKEN1, 0, 0);
        handler.syncBacking();
        _assertSharedInvariants();
        assertEq(handler.recoveriesClosed(), 1, "an expired shortfall is written off");
        assertLt(trackedBacking(), owed, "the write-off shrank the obligation");
        handler.recoverStray(_seedSelecting(keccak256(abi.encode("half", uint256(1), uint256(0)))));
        handler.recoverStray(_seedSelecting(keccak256(abi.encode("half", uint256(1), uint256(1)))));
        _assertSharedInvariants();
        assertEq(handler.strayAnnexations(), 2, "both halves found after write-off are annexed");
        assertEq(trackedBacking(), owed, "annexation restores the written-off obligation");

        _advanceRegistryNonce();
        handler.rebalance();
        _assertSharedInvariants();
        assertEq(_parkedStake(NETUID1), 0, "the rebalance spreads the parked backing again");

        handler.strandInTwoPiles(1, 2);
        _assertSharedInvariants();
        handler.syncBacking();
        _assertSharedInvariants();
        handler.recoverHeldStray(0);
        handler.recoverHeldStray(0);
        _assertSharedInvariants();
        assertEq(handler.strayCollections(), 2, "both halves under an open shortfall are collected");
        vm.expectEmit(true, false, false, true);
        emit IAlphaVaultAbi.BackingShortfallCleared(TOKEN1);
        handler.syncBacking();
        _assertSharedInvariants();
        assertEq(handler.recoveriesClosed(), 2, "full collection closes the recovery");
        assertEq(trackedBacking(), owed, "the position is whole again");
        _assertSharedInvariants();

        handler.accrueEmissions(10);
        _assertSharedInvariants();
        assertEq(_parkedStake(NETUID1), owed + 10e9, "emissions raise the parked pile by 10 alpha");
        handler.movePrice(1e8);
        assertEq(_alphaPriceRead(NETUID1), 0.1e18, "the price moves to 0.1 TAO per alpha");
        uint256 start = vm.getBlockTimestamp();
        handler.passTime(1 hours);
        assertEq(vm.getBlockTimestamp(), start + 1 hours, "time passes by the bounded hour");

        handler.replaceClone(0);
        _assertSharedInvariants();
        assertEq(handler.replacements(), 1, "anyone replaces the clone once its list is pinned full");
        assertEq(trackedBacking(), owed + 10e9, "the replacement carries the whole parked pile");
        assertEq(_parkedStake(NETUID1), owed + 10e9, "the new clone holds the parked pile");

        handler.swapHotkey(0, 1);
        _assertSharedInvariants();
        assertTrue(
            handler.touched(keccak256(abi.encode("swapped", uint256(1)))), "the swap's successor joins the campaign"
        );
        handler.rotateValidators(1);
        _assertSharedInvariants();
        assertEq(attestedHotkeys.length, 1, "the registry attests a one-hotkey set");
    }

    function _seedSelecting(bytes32 hotkey) private view returns (uint256 seed) {
        while (handler.sourceFor(seed) != hotkey) {
            ++seed;
            assertLt(seed, 1_000, "no seed below 1000 selects the hotkey");
        }
    }

    /// @dev A parked position rests until an attestation newer than the parking one arrives.
    function _advanceRegistryNonce() private {
        this.attest(attestedHotkeys);
    }
}
