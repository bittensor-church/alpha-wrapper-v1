// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";

contract HotkeySwapHandler is Test {
    AlphaVault public immutable vault;
    HotkeySwapInvariantTest public immutable harness;
    uint256 public immutable tokenId;
    uint256 public immutable netuid;
    address[] public actors;

    bytes32[] public liveKeys;
    bytes32[] public touchedHotkeys;
    mapping(bytes32 => bool) public touched;

    uint256 public wraps;
    uint256 public alphaExits;
    uint256 public taoExits;
    uint256 public drains;
    uint256 public rebalances;
    uint256 public freshSwaps;
    uint256 public reuseSwaps;
    uint256 public coldkeyAdoptions;
    uint256 public republishes;
    uint256 public syncs;

    constructor(
        AlphaVault _vault,
        HotkeySwapInvariantTest _harness,
        uint256 _tokenId,
        uint256 _netuid,
        address[] memory _actors,
        bytes32[] memory _validators
    ) {
        vault = _vault;
        harness = _harness;
        tokenId = _tokenId;
        netuid = _netuid;
        actors = _actors;
        liveKeys = _validators;
        for (uint256 i; i < _validators.length; ++i) {
            _remember(_validators[i]);
        }
    }

    function knownHotkeys() external view returns (bytes32[] memory) {
        return touchedHotkeys;
    }

    function wrap(uint256 actorSeed, uint256 amount, uint256 nameSeed) external {
        bytes32[] memory set = harness.attestedSet();
        bytes32 name = set[bound(nameSeed, 0, set.length - 1)];
        if (harness.wrapFor(_actor(actorSeed), bound(amount, 1e9, 200e9), name)) {
            ++wraps;
            harness.assertAttestedSlotsAnswerToTheirOwners();
        }
    }

    function unwrap(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        uint256 shares = bound(shareSeed, 1, balance);
        uint256 supply = vault.totalSupply(tokenId);
        uint256 holdings = harness.chainHoldings();
        bytes32 coldkey = keccak256(abi.encode(actor));
        uint256 before = harness.stakeOf(coldkey);
        vm.prank(actor);
        try vault.unwrap(tokenId, shares, coldkey, 0) {
            ++alphaExits;
            uint256 paid = harness.stakeOf(coldkey) - before;
            assertLe(paid * supply, shares * holdings + supply * harness.slack(), "an exit paid more than its share");
            if (shares != supply) harness.assertAttestedSlotsAnswerToTheirOwners();
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

    function drainSlot(uint256 actorSeed, uint256 slotSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        if (balance == 0 || slots.length == 0) return;
        uint256 slot = bound(slotSeed, 0, slots.length - 1);
        uint256 held = harness.vaultStakeAt(slots[slot].active);
        uint256 located = harness.locatedStake();
        if (held == 0 || located == 0) return;
        uint256 shares = (vault.totalSupply(tokenId) * held) / located + 1;
        if (shares > balance) return;
        uint256 keepOthers = ((1 << slots.length) - 1) ^ (1 << slot);
        vm.prank(actor);
        try vault.unwrapForTao(tokenId, shares, 0, keepOthers) {
            if (harness.vaultStakeAt(slots[slot].active) == 0) ++drains;
        } catch { }
    }

    function rebalance() external {
        try vault.rebalance(netuid) {
            ++rebalances;
            harness.assertAttestedSlotsAnswerToTheirOwners();
        } catch { }
    }

    function syncBacking() external {
        try vault.syncBacking(tokenId) {
            ++syncs;
        } catch { }
    }

    function swapToFreshKey(uint256 validatorSeed, uint256 keySeed, bool allSubnets) external {
        uint256 validator = _validator(validatorSeed);
        bytes32 to = keccak256(abi.encode("fresh", keySeed));
        if (touched[to]) return;
        _remember(to);
        harness.simulateSwap(liveKeys[validator], to, allSubnets);
        liveKeys[validator] = to;
        ++freshSwaps;
    }

    function swapOntoVacatedKey(uint256 validatorSeed, uint256 keySeed) external {
        uint256 validator = _validator(validatorSeed);
        bytes32[] memory vacated = harness.ownerlessKeys(touchedHotkeys);
        if (vacated.length == 0) return;
        bytes32 to = vacated[bound(keySeed, 0, vacated.length - 1)];
        harness.simulateSwap(liveKeys[validator], to, true);
        liveKeys[validator] = to;
        ++reuseSwaps;
    }

    function adoptColdkeyOf(uint256 validatorSeed, uint256 otherSeed) external {
        uint256 validator = _validator(validatorSeed);
        uint256 other = _validator(otherSeed);
        if (validator == other) return;
        if (harness.simulateColdkeySwap(liveKeys[validator], liveKeys[other], touchedHotkeys)) ++coldkeyAdoptions;
    }

    function republish(uint256 seed) external {
        uint256 count = bound(seed, 1, liveKeys.length);
        uint256 start = bound(uint256(keccak256(abi.encode(seed))), 0, liveKeys.length - 1);
        bytes32[] memory set = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            set[i] = liveKeys[(start + i) % liveKeys.length];
        }
        harness.attest(set);
        ++republishes;
    }

    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 4 hours));
    }

    function _remember(bytes32 hotkey) private {
        if (touched[hotkey]) return;
        touched[hotkey] = true;
        touchedHotkeys.push(hotkey);
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _validator(uint256 seed) private view returns (uint256) {
        return bound(seed, 0, liveKeys.length - 1);
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract HotkeySwapInvariantTest is AlphaVaultTestBase {
    HotkeySwapHandler internal handler;
    bytes32[] internal currentSet;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](2);
        actors[0] = alice;
        actors[1] = bob;
        _depositAndWrap(alice, NETUID1, 50 * ALPHA);

        currentSet = _hotkeys(hotkey1, hotkey2, hotkey3);
        handler = new HotkeySwapHandler(vault, this, TOKEN1, NETUID1, actors, currentSet);
        targetContract(address(handler));
    }

    function attestedSet() external view returns (bytes32[] memory) {
        return currentSet;
    }

    function slack() external pure returns (uint256) {
        return BACKING_SLACK_RAO;
    }

    function locatedStake() external view returns (uint256) {
        return lens.locatedStake(TOKEN1);
    }

    function vaultStakeAt(bytes32 hotkey) external view returns (uint256) {
        return _getVaultStake(hotkey, NETUID1);
    }

    function stakeOf(bytes32 coldkey) external view returns (uint256) {
        return _stakeAcross(handler.knownHotkeys(), coldkey, NETUID1);
    }

    function chainHoldings() public view returns (uint256) {
        return _vaultStakeAcross(handler.knownHotkeys(), NETUID1) + _parkedStake(NETUID1);
    }

    function ownerlessKeys(bytes32[] memory keys) external view returns (bytes32[] memory vacated) {
        uint256 count;
        vacated = new bytes32[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            (bool owned,) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(keys[i]);
            if (!owned) vacated[count++] = keys[i];
        }
        assembly {
            mstore(vacated, count)
        }
    }

    function wrapFor(address user, uint256 amount, bytes32 hotkey) external returns (bool wrapped) {
        _simulateAlphaDepositHotkey(user, NETUID1, amount, hotkey);
        vm.prank(user);
        try vault.wrap(NETUID1, hotkey, 0) {
            wrapped = true;
        } catch { }
    }

    function simulateSwap(bytes32 from, bytes32 to, bool allSubnets) external {
        if (allSubnets) _simulateFollowedSwap(NETUID1, from, to);
        else _simulatePerSubnetSwap(NETUID1, from, to);
    }

    function simulateColdkeySwap(bytes32 fromKey, bytes32 toKey, bytes32[] memory keys) external returns (bool) {
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        bytes32 oldOwner = staking.ownerOf(fromKey);
        bytes32 newOwner = staking.ownerOf(toKey);
        if (oldOwner == newOwner) return false;
        for (uint256 i; i < keys.length; ++i) {
            if (staking.ownerOf(keys[i]) == oldOwner) staking.setHotkeyOwner(keys[i], newOwner);
        }
        return true;
    }

    function attest(bytes32[] memory set) external {
        _setValidators(NETUID1, set, _evenWeights(set.length));
        currentSet = set;
    }

    function assertAttestedSlotsAnswerToTheirOwners() external view {
        (bytes32[] memory names,, bytes32[] memory owners) = registry.getValidators(NETUID1);
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 j; j < names.length; ++j) {
            for (uint256 i; i < slots.length; ++i) {
                if (slots[i].logical != names[j] || slots[i].tracked == 0) continue;
                assertTrue(VaultReads.ownedBy(slots[i].active, owners[j]), "attested stake rests on a stranger's key");
            }
        }
    }

    function test_ReusedNameAfterARetiredKey_ResolvesWithoutARepublish() public {
        handler.swapToFreshKey(0, 1, true);
        handler.rebalance();
        handler.drainSlot(0, 0);
        assertEq(handler.drains(), 1, "the first slot is emptied on its followed key");
        handler.swapToFreshKey(0, 2, true);
        handler.swapOntoVacatedKey(1, 0);
        assertEq(handler.reuseSwaps(), 1, "the second validator takes the vacated first name");
        assertEq(handler.liveKeys(1), hotkey1, "which is the first validator's attested name");

        handler.rebalance();

        assertEq(handler.rebalances(), 2, "the rebalance succeeds without a new attestation");
        assertEq(vault.recordedSlots(TOKEN1)[0].active, handler.liveKeys(0), "the emptied slot follows to the live key");
        _assertAllInvariants();
    }

    function test_HandlerReachesEverySuccessPath() public {
        handler.wrap(1, 100e9, 0);
        handler.unwrap(0, 1e18);
        handler.unwrapForTao(0, 1e18);
        handler.drainSlot(1, 2);
        handler.swapToFreshKey(2, 7, false);
        handler.swapToFreshKey(2, 8, true);
        handler.swapOntoVacatedKey(0, 0);
        handler.syncBacking();
        handler.adoptColdkeyOf(0, 1);
        handler.republish(3);
        handler.rebalance();

        assertEq(handler.wraps(), 1, "a deposit wraps");
        assertEq(handler.alphaExits(), 1, "an alpha exit pays");
        assertEq(handler.taoExits(), 1, "a TAO exit pays");
        assertEq(handler.drains(), 1, "a masked TAO exit empties one slot");
        assertEq(handler.freshSwaps(), 2, "a validator renames per subnet and across subnets");
        assertEq(handler.reuseSwaps(), 1, "a validator takes a vacated key");
        assertEq(handler.coldkeyAdoptions(), 1, "a validator moves under another operator's coldkey");
        assertEq(handler.republishes(), 1, "the registry publishes the live keys");
        assertEq(handler.rebalances(), 1, "the rebalance lands the new set");
        assertEq(handler.syncs(), 1, "a sync records the unobserved rename");
        _assertAllInvariants();
    }

    function _assertAllInvariants() private view {
        invariant_NoTwoSlotsAnswerForOneKey();
        invariant_ReportedBackingNeverExceedsWhatTheChainHolds();
        invariant_TrackedBackingIsBoundedByChainHoldings();
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
        assertLe(lens.locatedStake(TOKEN1), chainHoldings(), "the position reports backing the chain does not hold");
    }

    function invariant_TrackedBackingIsBoundedByChainHoldings() public view {
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        uint256 tracked;
        for (uint256 i; i < slots.length; ++i) {
            tracked += slots[i].tracked;
        }
        assertLe(tracked, chainHoldings() + BACKING_SLACK_RAO * slots.length, "the record expects more than exists");
    }
}
