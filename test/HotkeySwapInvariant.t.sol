// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BackingCampaignHandler, BackingCampaignHarness } from "./helpers/BackingCampaign.sol";
import { MockStaking } from "./mocks/MockStaking.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { STAKING_PRECOMPILE } from "src/interfaces/IStaking.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";

contract HotkeySwapHandler is BackingCampaignHandler {
    /// @dev Covers the virtual-share rounding in the share quote so the asked amount clears the slot.
    uint256 private constant DRAIN_MARGIN_RAO = 1e6;

    bytes32[] public liveKeys;

    uint256 public drains;
    uint256 public freshSwaps;
    uint256 public reuseSwaps;
    uint256 public coldkeySwaps;
    uint256 public republishes;

    constructor(
        AlphaVault _vault,
        HotkeySwapInvariantTest _harness,
        uint256 _tokenId,
        uint256 _netuid,
        address[] memory _actors,
        bytes32[] memory _validators
    ) BackingCampaignHandler(_vault, _harness, _tokenId, _netuid, _actors, _validators) {
        liveKeys = _validators;
    }

    function drainSlot(uint256 actorSeed, uint256 slotSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        if (balance == 0 || slots.length == 0) return;
        uint256 slot = bound(slotSeed, 0, slots.length - 1);
        uint256 held = _swaps().vaultStakeAt(slots[slot].active);
        uint256 located = _swaps().locatedStake();
        if (held == 0 || located == 0) return;
        uint256 shares = (vault.totalSupply(tokenId) * (held + DRAIN_MARGIN_RAO)) / located + 1;
        if (shares > balance) return;
        uint256 keepOthers = ((1 << slots.length) - 1) ^ (1 << slot);
        vm.prank(actor);
        try vault.unwrapForTao(tokenId, shares, 0, keepOthers) {
            if (_swaps().vaultStakeAt(slots[slot].active) == 0) ++drains;
        } catch { }
    }

    function swapToFreshKey(uint256 validatorSeed, uint256 keySeed, bool allSubnets) external {
        uint256 validator = _validator(validatorSeed);
        bytes32 to = keccak256(abi.encode("fresh", keySeed));
        if (touched[to]) return;
        _remember(to);
        _swaps().simulateSwap(liveKeys[validator], to, allSubnets);
        liveKeys[validator] = to;
        ++freshSwaps;
    }

    function swapOntoVacatedKey(uint256 validatorSeed, uint256 keySeed, bool allSubnets) external {
        uint256 validator = _validator(validatorSeed);
        bytes32[] memory vacated = _swaps().ownerlessKeys();
        if (vacated.length == 0) return;
        bytes32 to = vacated[bound(keySeed, 0, vacated.length - 1)];
        _swaps().simulateSwap(liveKeys[validator], to, allSubnets);
        liveKeys[validator] = to;
        ++reuseSwaps;
    }

    function swapColdkey(uint256 validatorSeed, uint256 coldkeySeed) external {
        bytes32 destination = keccak256(abi.encode("coldkey", coldkeySeed));
        if (_swaps().simulateColdkeySwap(liveKeys[_validator(validatorSeed)], destination)) ++coldkeySwaps;
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

    function _afterAllocation() internal view override {
        _swaps().assertAttestedStakeRestsWithItsOwners();
    }

    function _validator(uint256 seed) private view returns (uint256) {
        return bound(seed, 0, liveKeys.length - 1);
    }

    function _swaps() private view returns (HotkeySwapInvariantTest) {
        return HotkeySwapInvariantTest(address(harness));
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract HotkeySwapInvariantTest is BackingCampaignHarness {
    HotkeySwapHandler internal handler;

    function setUp() public override {
        super.setUp();
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setHotkeyOwner(hotkey2, staking.ownerOf(hotkey1));
        currentSet = _hotkeys(hotkey1, hotkey2, hotkey3);
        this.attest(currentSet);

        address[] memory actors = new address[](2);
        actors[0] = alice;
        actors[1] = bob;
        _depositAndWrap(alice, NETUID1, 50 * ALPHA);

        handler = new HotkeySwapHandler(vault, this, TOKEN1, NETUID1, actors, currentSet);
        targetContract(address(handler));
    }

    function _campaign() internal view override returns (BackingCampaignHandler) {
        return handler;
    }

    function locatedStake() external view returns (uint256) {
        return lens.locatedStake(TOKEN1);
    }

    function vaultStakeAt(bytes32 hotkey) external view returns (uint256) {
        return _getVaultStake(hotkey, NETUID1);
    }

    function ownerlessKeys() external view returns (bytes32[] memory vacated) {
        bytes32[] memory keys = handler.knownHotkeys();
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

    function simulateSwap(bytes32 from, bytes32 to, bool allSubnets) external {
        if (allSubnets) _simulateFollowedSwap(NETUID1, from, to);
        else _simulatePerSubnetSwap(NETUID1, from, to);
    }

    /// @dev A validator's coldkey swap, which the chain only allows onto a coldkey holding nothing yet.
    function simulateColdkeySwap(bytes32 liveKey, bytes32 destination) external returns (bool) {
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        (bool exists,) = staking.getHotkeyOwner(destination);
        if (exists || staking.ownerOf(liveKey) == destination) return false;
        staking.simulateColdkeySwap(staking.ownerOf(liveKey), destination, NETUID1, handler.knownHotkeys());
        return true;
    }

    function assertAttestedStakeRestsWithItsOwners() external view {
        (bytes32[] memory names,, bytes32[] memory owners) = registry.getValidators(NETUID1);
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 j; j < names.length; ++j) {
            for (uint256 i; i < slots.length; ++i) {
                if (slots[i].logical != names[j] || slots[i].tracked == 0) continue;
                (bool exists, bytes32 owner) = MockStaking(STAKING_PRECOMPILE).getHotkeyOwner(slots[i].active);
                assertTrue(exists, "attested stake rests on an ownerless key");
                assertEq(owner, owners[j], "attested stake rests on a stranger's key");
            }
        }
    }

    function test_ReusedNameAfterARetiredKey_ResolvesWithoutARepublish() public {
        handler.swapToFreshKey(0, 1, true);
        _assertSharedInvariants();
        handler.rebalance();
        _assertSharedInvariants();
        handler.drainSlot(0, 0);
        _assertSharedInvariants();
        assertEq(handler.drains(), 1, "the first slot is emptied on its followed key");
        handler.swapToFreshKey(0, 2, true);
        _assertSharedInvariants();
        handler.swapOntoVacatedKey(1, 0, true);
        _assertSharedInvariants();
        assertEq(handler.reuseSwaps(), 1, "the second validator takes the vacated first name");
        assertEq(handler.liveKeys(1), hotkey1, "which is the first validator's attested name");

        handler.rebalance();
        _assertSharedInvariants();

        assertEq(handler.rebalances(), 2, "the rebalance succeeds without a new attestation");
        assertEq(vault.recordedSlots(TOKEN1)[0].active, handler.liveKeys(0), "the emptied slot follows to the live key");
        _assertSharedInvariants();
    }

    function test_ParkedPartialExit_IsMeasuredOnTheParkingHotkey() public {
        handler.swapToFreshKey(0, 1, true);
        _assertSharedInvariants();
        handler.swapToFreshKey(0, 2, true);
        _assertSharedInvariants();
        handler.syncBacking();
        _assertSharedInvariants();
        vm.warp(lens.writeOffDeadline(TOKEN1));
        handler.syncBacking();
        _assertSharedInvariants();
        assertTrue(vault.awaitingAttestation(TOKEN1), "two unobserved renames park the position");
        assertGt(_parkedStake(NETUID1), 0, "with the located backing on the parking hotkey");
        bytes32 recipient = keccak256(abi.encode(alice));
        uint256 before = _getStakeForColdkey(vault.parkingHotkey(), recipient, NETUID1);

        handler.unwrap(0, vault.balanceOf(alice, TOKEN1) / 4);
        _assertSharedInvariants();

        assertEq(handler.alphaExits(), 1, "the parked position pays the alpha exit");
        assertGt(handler.lastAlphaPaid(), 0, "and the payout is measured");
        assertEq(
            handler.lastAlphaPaid(),
            _getStakeForColdkey(vault.parkingHotkey(), recipient, NETUID1) - before,
            "as the recipient's increase on the parking hotkey"
        );
    }

    function test_HandlerReachesEverySuccessPath() public {
        handler.wrap(1, 100e9, 0);
        _assertSharedInvariants();
        handler.unwrap(0, 1e18);
        _assertSharedInvariants();
        handler.unwrapForTao(0, 1e18);
        _assertSharedInvariants();
        handler.drainSlot(1, 2);
        _assertSharedInvariants();
        handler.swapToFreshKey(2, 7, false);
        _assertSharedInvariants();
        handler.swapToFreshKey(2, 8, true);
        _assertSharedInvariants();
        handler.swapOntoVacatedKey(0, 0, true);
        _assertSharedInvariants();
        handler.syncBacking();
        _assertSharedInvariants();
        handler.swapColdkey(0, 5);
        _assertSharedInvariants();
        handler.republish(3);
        _assertSharedInvariants();
        handler.rebalance();
        _assertSharedInvariants();

        assertEq(handler.wraps(), 1, "a deposit wraps");
        assertEq(handler.alphaExits(), 1, "an alpha exit pays");
        assertEq(handler.taoExits(), 1, "a TAO exit pays");
        assertEq(handler.drains(), 1, "a masked TAO exit empties one slot");
        assertEq(handler.freshSwaps(), 2, "a validator renames per subnet and across subnets");
        assertEq(handler.reuseSwaps(), 1, "a validator takes a vacated key");
        assertEq(handler.syncs(), 1, "a sync records the unobserved rename");
        assertEq(handler.coldkeySwaps(), 1, "an operator moves to a fresh coldkey");
        assertEq(handler.republishes(), 1, "the registry publishes the live keys");
        assertEq(handler.rebalances(), 1, "the rebalance lands the new set");
        _assertSharedInvariants();
    }
}
