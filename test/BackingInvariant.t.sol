// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BackingCampaignHandler, BackingCampaignHarness } from "./helpers/BackingCampaign.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";

contract BackingHandler is BackingCampaignHandler {
    uint256 public strayAnnexations;
    uint256 public strayCollections;

    constructor(
        AlphaVault _vault,
        BackingInvariantTest _harness,
        uint256 _tokenId,
        uint256 _netuid,
        address[] memory _actors,
        bytes32[] memory _seedHotkeys
    ) BackingCampaignHandler(_vault, _harness, _tokenId, _netuid, _actors, _seedHotkeys) { }

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

    function sourceFor(uint256 sourceSeed) public view returns (bytes32) {
        return
            touchedHotkeys[bound(uint256(keccak256(abi.encode(sourceSeed, uint256(0)))), 0, touchedHotkeys.length - 1)];
    }

    function recoverStray(uint256 sourceSeed) external {
        _recover(sourceFor(sourceSeed));
    }

    function recoverHeldStray(uint256 sourceSeed) external {
        bytes32[] memory held = _backing().touchedKeysHoldingStake(touchedHotkeys);
        if (held.length == 0) return;
        _recover(held[bound(sourceSeed, 0, held.length - 1)]);
    }

    function _recover(bytes32 source) private {
        uint256 slotsBefore = vault.recordedSlots(tokenId).length;
        if (slotsBefore == 0) return;
        uint256 owedBefore = harness.trackedBacking();
        uint256 supplyBefore = vault.totalSupply(tokenId);
        try vault.recoverStray(tokenId, source) {
            (uint256 since,) = vault.recovery(tokenId);
            if (since == 0) {
                ++strayAnnexations;
                bool[] memory covered = _backing().coveredSlots();
                for (uint256 i; i < covered.length; ++i) {
                    assertTrue(covered[i], "annexation left a slot short");
                }
            } else {
                ++strayCollections;
                assertEq(harness.trackedBacking(), owedBefore, "collection changed the obligation");
            }
            assertEq(vault.totalSupply(tokenId), supplyBefore, "recovery changed the supply");
            // The record is rewritten from live balances; those balances must still answer for what was owed.
            assertGe(
                harness.trackedBacking() + _backing().recoverySlack(slotsBefore),
                owedBefore,
                "recovery discarded part of the obligation"
            );
        } catch { }
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

    function _backing() private view returns (BackingInvariantTest) {
        return BackingInvariantTest(address(harness));
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract BackingInvariantTest is BackingCampaignHarness {
    BackingHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](2);
        actors[0] = alice;
        actors[1] = bob;
        _depositAndWrap(alice, NETUID1, 50 * ALPHA);

        currentSet = _hotkeys(hotkey1, hotkey2, hotkey3);
        bytes32[] memory seeds = _hotkeys(hotkey1, hotkey2, hotkey3);
        handler = new BackingHandler(vault, this, TOKEN1, NETUID1, actors, seeds);
        targetContract(address(handler));
    }

    function _campaign() internal view override returns (BackingCampaignHandler) {
        return handler;
    }

    function backingIntact() external view returns (bool) {
        return lens.isBackingIntact(TOKEN1);
    }

    function recoverySlack(uint256 slots) external pure returns (uint256) {
        return BACKING_SLACK_RAO * slots;
    }

    function coveredSlots() external view returns (bool[] memory covered) {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        covered = new bool[](slots.length);
        bytes32 coldkey = _subnetColdkey(NETUID1);
        for (uint256 i; i < slots.length; ++i) {
            uint256 held = _getStakeForColdkey(slots[i].active, coldkey, NETUID1);
            // Check the chain ledger directly; recovery must leave each persisted slot covered.
            covered[i] = held >= slots[i].tracked || slots[i].tracked - held <= BACKING_SLACK_RAO;
        }
    }

    function touchedKeysHoldingStake(bytes32[] memory keys) external view returns (bytes32[] memory held) {
        uint256 count;
        held = new bytes32[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            if (_getVaultStake(keys[i], NETUID1) != 0) held[count++] = keys[i];
        }
        assembly {
            mstore(held, count)
        }
    }

    function simulateSwap(bytes32 from, bytes32 to) external {
        _simulateFollowedSwap(NETUID1, from, to);
    }

    function simulateSilentMove(bytes32 from, bytes32 to) external {
        _simulateOffVaultSwap(NETUID1, from, to);
    }

    function test_ReplayMergedStrayRecovery_PreservesBackingInvariants() public {
        handler.swapWithoutAnEdge(3920, 702498195375104724870804370661893358612984996200603330987954554);
        handler.swapWithoutAnEdge(21936, 9555);
        handler.swapWithoutAnEdge(0, 46484125467125653278869020054723548665048815226470);
        handler.syncBacking();
        handler.recoverStray(361656362808158655897425226168322);
        handler.swapHotkey(395928111782571441, 47594521996258548997527314557814977391483923631630328760470);
        handler.swapWithoutAnEdge(115792089237316195423570985008687907853269984665640564039457584007913129639932, 2);
        handler.syncBacking();
        handler.recoverStray(496832458824593621465406068473474564241632359248770171723107483670860501638);
        handler.swapHotkey(1000000000000000000, 518);
        handler.swapHotkey(39284778829218561959962831765498513039391595077, 1);
        handler.swapHotkey(4668825657844413095552775974875155388807116336350818157329463057335574, 863968505977431908);
        handler.rotateValidators(25670646866713597079810818809857953515987733532491365243132352747204520724);
        handler.wrap(4982, 2038218518, 126689249586524825498559537986693588869175255532239560737778380983908754);
        handler.swapHotkey(
            5022836071830231965563198741131435959745735624404810078992442116285814296610,
            10708288936997174409238467093412100671917613552582
        );
        handler.swapWithoutAnEdge(2720838758, 2641);
        handler.swapWithoutAnEdge(2151, 2641);
        handler.syncBacking();
        handler.recoverStray(115792089237316195423570985008687907853269984665640564039457584007913129639935);

        _assertSharedInvariants();
    }

    function test_HandlerReachesEverySuccessPath() public {
        handler.wrap(1, 100e9, 0);
        assertEq(handler.wraps(), 1, "the deposit wraps into shares");
        handler.unwrap(0, 1e18);
        handler.unwrapForTao(0, 1e18);
        assertEq(handler.alphaExits(), 1, "the alpha exit succeeds from a healthy position");
        assertEq(handler.taoExits(), 1, "the TAO exit succeeds from a healthy position");
        uint256 owed = trackedBacking();

        handler.swapWithoutAnEdge(0, 1);
        handler.syncBacking();
        vm.warp(lens.writeOffDeadline(TOKEN1));
        vm.expectEmit(true, false, false, false);
        emit IAlphaVaultAbi.BackingWrittenOff(TOKEN1, 0, 0);
        handler.syncBacking();
        assertEq(handler.recoveriesClosed(), 1, "an expired shortfall is written off");
        assertLt(trackedBacking(), owed, "the write-off shrank the obligation");
        handler.recoverStray(_seedSelectingLastTouched());
        assertEq(handler.strayAnnexations(), 1, "a stray found after write-off is annexed");
        assertEq(trackedBacking(), owed, "annexation restores the written-off obligation");

        _advanceRegistryNonce();
        handler.rebalance();
        assertEq(_parkedStake(NETUID1), 0, "the rebalance spreads the parked backing again");

        handler.swapWithoutAnEdge(0, 1);
        handler.syncBacking();
        handler.recoverHeldStray(0);
        assertEq(handler.strayCollections(), 1, "a stray under an open shortfall is collected");
        vm.expectEmit(true, false, false, true);
        emit IAlphaVaultAbi.BackingShortfallCleared(TOKEN1);
        handler.syncBacking();
        assertEq(handler.recoveriesClosed(), 2, "full collection closes the recovery");
        assertEq(trackedBacking(), owed, "the position is whole again");
        _assertSharedInvariants();
    }

    function _seedSelectingLastTouched() private view returns (uint256 seed) {
        bytes32[] memory keys = handler.knownHotkeys();
        while (handler.sourceFor(seed) != keys[keys.length - 1]) {
            ++seed;
        }
    }

    /// @dev A parked position rests until an attestation newer than the parking one arrives.
    function _advanceRegistryNonce() private {
        this.attest(currentSet);
    }
}
