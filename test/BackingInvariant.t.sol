// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";
import { IAlphaVaultAbi } from "src/interfaces/IAlphaVaultAbi.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";

contract BackingHandler is Test {
    AlphaVault public immutable vault;
    BackingInvariantTest public immutable harness;
    uint256 public immutable tokenId;
    uint256 public immutable netuid;
    address[] public actors;

    /// @dev Independent chain-total oracle, including keys no longer tracked by the vault.
    bytes32[] public touchedHotkeys;
    mapping(bytes32 => bool) public touched;

    uint256 public wraps;
    uint256 public alphaExits;
    uint256 public taoExits;
    uint256 public strayAnnexations;
    uint256 public strayCollections;
    uint256 public recoveriesClosed;

    constructor(
        AlphaVault _vault,
        BackingInvariantTest _harness,
        uint256 _tokenId,
        uint256 _netuid,
        address[] memory _actors,
        bytes32[] memory _seedHotkeys
    ) {
        vault = _vault;
        harness = _harness;
        tokenId = _tokenId;
        netuid = _netuid;
        actors = _actors;
        for (uint256 i; i < _seedHotkeys.length; ++i) {
            _remember(_seedHotkeys[i]);
        }
    }

    function _remember(bytes32 hotkey) internal {
        if (touched[hotkey]) return;
        touched[hotkey] = true;
        touchedHotkeys.push(hotkey);
    }

    function knownHotkeys() external view returns (bytes32[] memory) {
        return touchedHotkeys;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _attested(uint256 seed) private view returns (bytes32) {
        bytes32[] memory set = harness.attestedSet();
        return set[bound(seed, 0, set.length - 1)];
    }

    function wrap(uint256 actorSeed, uint256 amount, uint256 hotkeySeed) external {
        // Alpha in RAO: a TAO exit narrows slot balances to the chain's 64-bit stake amounts.
        if (harness.wrapFor(_actor(actorSeed), bound(amount, 1e9, 200e9), _attested(hotkeySeed))) ++wraps;
    }

    function unwrap(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        vm.prank(actor);
        try vault.unwrap(tokenId, bound(shareSeed, 1, balance), keccak256(abi.encode(actor)), 0) {
            ++alphaExits;
        } catch { }
    }

    function unwrapForTao(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        vm.prank(actor);
        try vault.unwrapForTao(tokenId, bound(shareSeed, 1, balance), 0) {
            ++taoExits;
        } catch { }
    }

    function rebalance() external {
        try vault.rebalance(netuid) { } catch { }
    }

    function syncBacking() external {
        (uint256 shortSinceBefore,) = vault.recovery(tokenId);
        try vault.syncBacking(tokenId) {
            (uint256 shortSinceAfter,) = vault.recovery(tokenId);
            if (shortSinceBefore != 0 && shortSinceAfter == 0) ++recoveriesClosed;
        } catch { }
    }

    function swapHotkey(uint256 fromSeed, uint256 toSeed) external {
        bytes32 from = touchedHotkeys[bound(fromSeed, 0, touchedHotkeys.length - 1)];
        bytes32 to = keccak256(abi.encode("swapped", toSeed));
        if (from == to) return;
        _remember(to);
        harness.simulateSwap(from, to);
    }

    function swapWithoutAnEdge(uint256 fromSeed, uint256 toSeed) external {
        bytes32 from = touchedHotkeys[bound(fromSeed, 0, touchedHotkeys.length - 1)];
        bytes32 to = keccak256(abi.encode("stray", toSeed));
        if (from == to) return;
        _remember(to);
        harness.simulateSilentMove(from, to);
    }

    function sourceFor(uint256 sourceSeed) public view returns (bytes32) {
        return
            touchedHotkeys[bound(uint256(keccak256(abi.encode(sourceSeed, uint256(0)))), 0, touchedHotkeys.length - 1)];
    }

    function recoverStray(uint256 sourceSeed) external {
        _recover(sourceFor(sourceSeed));
    }

    function recoverHeldStray(uint256 sourceSeed) external {
        bytes32[] memory held = harness.touchedKeysHoldingStake(touchedHotkeys);
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
                bool[] memory covered = harness.coveredSlots();
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
                harness.trackedBacking() + harness.recoverySlack(slotsBefore),
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

    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 4 hours));
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract BackingInvariantTest is AlphaVaultTestBase {
    BackingHandler internal handler;
    bytes32[] internal currentSet;

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

    function attestedSet() external view returns (bytes32[] memory) {
        return currentSet;
    }

    function backingIntact() external view returns (bool) {
        return lens.isBackingIntact(TOKEN1);
    }

    function trackedBacking() public view returns (uint256 owed) {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            owed += slots[i].tracked;
        }
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

    function wrapFor(address user, uint256 amount, bytes32 hotkey) external returns (bool wrapped) {
        _simulateAlphaDepositHotkey(user, NETUID1, amount, hotkey);
        vm.prank(user);
        try vault.wrap(NETUID1, hotkey, 0) {
            wrapped = true;
        } catch { }
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

    function attest(bytes32[] memory set) external {
        uint16[] memory weights = new uint16[](set.length);
        uint16 assigned;
        for (uint256 i; i + 1 < set.length; ++i) {
            weights[i] = uint16(BPS_BASE / set.length);
            assigned += weights[i];
        }
        weights[set.length - 1] = BPS_BASE - assigned;
        for (uint256 i; i < set.length; ++i) {
            _simulateHotkeyOwnerPresent(set[i]);
        }
        _setValidators(NETUID1, set, weights);
        currentSet = set;
    }

    function test_ReplayMergedStrayRecovery_PreservesBackingInvariants() public {
        handler.swapWithoutAnEdge(3920, 702498195375104724870804370661893358612984996200603330987954554);
        _assertAllInvariants();
        handler.swapWithoutAnEdge(21936, 9555);
        _assertAllInvariants();
        handler.swapWithoutAnEdge(0, 46484125467125653278869020054723548665048815226470);
        _assertAllInvariants();
        handler.syncBacking();
        _assertAllInvariants();
        handler.recoverStray(361656362808158655897425226168322);
        _assertAllInvariants();
        handler.swapHotkey(395928111782571441, 47594521996258548997527314557814977391483923631630328760470);
        _assertAllInvariants();
        handler.swapWithoutAnEdge(115792089237316195423570985008687907853269984665640564039457584007913129639932, 2);
        _assertAllInvariants();
        handler.syncBacking();
        _assertAllInvariants();
        handler.recoverStray(496832458824593621465406068473474564241632359248770171723107483670860501638);
        _assertAllInvariants();
        handler.swapHotkey(1000000000000000000, 518);
        _assertAllInvariants();
        handler.swapHotkey(39284778829218561959962831765498513039391595077, 1);
        _assertAllInvariants();
        handler.swapHotkey(4668825657844413095552775974875155388807116336350818157329463057335574, 863968505977431908);
        _assertAllInvariants();
        handler.rotateValidators(25670646866713597079810818809857953515987733532491365243132352747204520724);
        _assertAllInvariants();
        handler.wrap(4982, 2038218518, 126689249586524825498559537986693588869175255532239560737778380983908754);
        _assertAllInvariants();
        handler.swapHotkey(
            5022836071830231965563198741131435959745735624404810078992442116285814296610,
            10708288936997174409238467093412100671917613552582
        );
        _assertAllInvariants();
        handler.swapWithoutAnEdge(2720838758, 2641);
        _assertAllInvariants();
        handler.swapWithoutAnEdge(2151, 2641);
        _assertAllInvariants();
        handler.syncBacking();
        _assertAllInvariants();
        handler.recoverStray(115792089237316195423570985008687907853269984665640564039457584007913129639935);
        _assertAllInvariants();
    }

    function test_HandlerReachesEverySuccessPath() public {
        handler.wrap(1, 100e9, 0);
        _assertAllInvariants();
        assertEq(handler.wraps(), 1, "the deposit wraps into shares");
        handler.unwrap(0, 1e18);
        _assertAllInvariants();
        handler.unwrapForTao(0, 1e18);
        _assertAllInvariants();
        assertEq(handler.alphaExits(), 1, "the alpha exit succeeds from a healthy position");
        assertEq(handler.taoExits(), 1, "the TAO exit succeeds from a healthy position");
        uint256 owed = trackedBacking();

        handler.swapWithoutAnEdge(0, 1);
        _assertAllInvariants();
        handler.syncBacking();
        _assertAllInvariants();
        vm.warp(lens.writeOffDeadline(TOKEN1));
        _assertAllInvariants();
        vm.expectEmit(true, false, false, false);
        emit IAlphaVaultAbi.BackingWrittenOff(TOKEN1, 0, 0);
        handler.syncBacking();
        _assertAllInvariants();
        assertEq(handler.recoveriesClosed(), 1, "an expired shortfall is written off");
        assertLt(trackedBacking(), owed, "the write-off shrank the obligation");
        handler.recoverStray(_seedSelectingLastTouched());
        _assertAllInvariants();
        assertEq(handler.strayAnnexations(), 1, "a stray found after write-off is annexed");
        assertEq(trackedBacking(), owed, "annexation restores the written-off obligation");

        _advanceRegistryNonce();
        _assertAllInvariants();
        handler.rebalance();
        _assertAllInvariants();
        assertEq(_parkedStake(NETUID1), 0, "the rebalance spreads the parked backing again");

        handler.swapWithoutAnEdge(0, 1);
        _assertAllInvariants();
        handler.syncBacking();
        _assertAllInvariants();
        handler.recoverHeldStray(0);
        _assertAllInvariants();
        assertEq(handler.strayCollections(), 1, "a stray under an open shortfall is collected");
        vm.expectEmit(true, false, false, true);
        emit IAlphaVaultAbi.BackingShortfallCleared(TOKEN1);
        handler.syncBacking();
        _assertAllInvariants();
        assertEq(handler.recoveriesClosed(), 2, "full collection closes the recovery");
        assertEq(trackedBacking(), owed, "the position is whole again");
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

    function _assertAllInvariants() private view {
        invariant_TotalTrackedBackingIsBoundedByCurrentChainHoldings();
        invariant_NoTwoSlotsAnswerForOneKey();
        invariant_ReportedBackingNeverExceedsWhatTheChainHolds();
    }

    function invariant_NoTwoSlotsAnswerForOneKey() public view {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i].active != slots[j].active, "two slots answer for one key");
            }
        }
    }

    function invariant_ReportedBackingNeverExceedsWhatTheChainHolds() public view {
        assertLe(lens.locatedStake(TOKEN1), _chainHoldings(), "the position reports backing the chain does not hold");
    }

    function invariant_TotalTrackedBackingIsBoundedByCurrentChainHoldings() public view {
        uint256 slots = vault.recordedSlots(TOKEN1).length;
        assertLe(trackedBacking(), _chainHoldings() + BACKING_SLACK_RAO * slots, "the record expects more than exists");
    }

    /// @dev Every key the campaign touched plus the parking hotkey, where recoveries and write-offs land.
    function _chainHoldings() private view returns (uint256 held) {
        bytes32[] memory keys = handler.knownHotkeys();
        for (uint256 i; i < keys.length; ++i) {
            held += _getVaultStake(keys[i], NETUID1);
        }
        held += _parkedStake(NETUID1);
    }
}
