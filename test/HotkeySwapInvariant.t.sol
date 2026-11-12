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

    bytes32[] public validatorHotkeys;

    uint256 public drains;
    uint256 public freshSwaps;
    uint256 public reuseSwaps;
    uint256 public coldkeySwaps;
    uint256 public republishes;

    constructor(
        AlphaVault _vault,
        HotkeySwapCampaignSetup _harness,
        uint256 _tokenId,
        uint256 _netuid,
        address[] memory _actors,
        bytes32[] memory _validators
    ) BackingCampaignHandler(_vault, _harness, _tokenId, _netuid, _actors, _validators) {
        validatorHotkeys = _validators;
    }

    function drainSlot(uint256 actorSeed, uint256 slotSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        VaultReads.Slot[] memory slots = vault.recordedSlots(tokenId);
        if (balance == 0 || slots.length == 0) return;
        uint256 slot = bound(slotSeed, 0, slots.length - 1);
        uint256 held = harness.vaultStakeAt(slots[slot].stakedUnder);
        uint256 located = _swaps().locatedStake();
        // The pool refuses a sale that would pay nothing.
        if (located == 0 || MockStaking(STAKING_PRECOMPILE).quoteTaoOut(uint16(netuid), held) == 0) return;
        uint256 shares = (vault.totalSupply(tokenId) * (held + DRAIN_MARGIN_RAO)) / located + 1;
        if (shares > balance) return;
        uint256 keepOthers = ((1 << slots.length) - 1) ^ (1 << slot);
        if (_sellForTao(actor, shares, keepOthers) && harness.vaultStakeAt(slots[slot].stakedUnder) == 0) ++drains;
    }

    function swapToFreshHotkey(uint256 validatorSeed, uint256 hotkeySeed, bool allSubnets) external {
        uint256 validator = _validator(validatorSeed);
        bytes32 to = keccak256(abi.encode("fresh", hotkeySeed));
        if (touched[to]) return;
        _remember(to);
        _swaps().simulateSwap(validatorHotkeys[validator], to, allSubnets);
        validatorHotkeys[validator] = to;
        ++freshSwaps;
    }

    function swapOntoVacatedHotkey(uint256 validatorSeed, uint256 hotkeySeed, bool allSubnets) external {
        uint256 validator = _validator(validatorSeed);
        bytes32[] memory vacated = _swaps().ownerlessHotkeys();
        if (vacated.length == 0) return;
        bytes32 to = vacated[bound(hotkeySeed, 0, vacated.length - 1)];
        _swaps().simulateSwap(validatorHotkeys[validator], to, allSubnets);
        validatorHotkeys[validator] = to;
        ++reuseSwaps;
    }

    function swapColdkey(uint256 validatorSeed, uint256 coldkeySeed) external {
        bytes32 destination = keccak256(abi.encode("coldkey", coldkeySeed));
        bytes32 validatorHotkey = validatorHotkeys[_validator(validatorSeed)];
        uint256 located = _swaps().locatedStake();
        bool intact = _swaps().backingIntact();
        if (!_swaps().simulateColdkeySwap(validatorHotkey, destination)) return;
        ++coldkeySwaps;
        assertEq(_swaps().locatedStake(), located, "a validator's coldkey swap leaves the located backing");
        assertEq(_swaps().backingIntact(), intact, "a validator's coldkey swap leaves the backing's coverage");
    }

    function republish(uint256 seed) external {
        uint256 count = bound(seed, 1, validatorHotkeys.length);
        uint256 start = bound(uint256(keccak256(abi.encode(seed))), 0, validatorHotkeys.length - 1);
        bytes32[] memory set = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            set[i] = validatorHotkeys[(start + i) % validatorHotkeys.length];
        }
        harness.attest(set);
        ++republishes;
    }

    function _afterAllocation() internal view override {
        _swaps().assertAttestedStakeRestsOnOwnedHotkeys();
    }

    function _validator(uint256 seed) private view returns (uint256) {
        return bound(seed, 0, validatorHotkeys.length - 1);
    }

    function _swaps() private view returns (HotkeySwapCampaignSetup) {
        return HotkeySwapCampaignSetup(address(harness));
    }
}

abstract contract HotkeySwapCampaignSetup is BackingCampaignHarness {
    HotkeySwapHandler internal handler;

    function setUp() public override {
        super.setUp();
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        staking.setHotkeyOwner(hotkey2, staking.ownerOf(hotkey1));
        attestedHotkeys = _hotkeys(hotkey1, hotkey2, hotkey3);
        this.attest(attestedHotkeys);

        address[] memory actors = new address[](2);
        actors[0] = alice;
        actors[1] = bob;
        _depositAndWrap(alice, NETUID1, 50 * ALPHA);

        handler = new HotkeySwapHandler(vault, this, TOKEN1, NETUID1, actors, attestedHotkeys);
        targetContract(address(handler));
    }

    function _campaign() internal view override returns (BackingCampaignHandler) {
        return handler;
    }

    function locatedStake() external view returns (uint256) {
        return lens.locatedStake(TOKEN1);
    }

    function backingIntact() external view returns (bool) {
        return lens.isBackingIntact(TOKEN1);
    }

    function ownerlessHotkeys() external view returns (bytes32[] memory vacated) {
        bytes32[] memory known = handler.knownHotkeys();
        uint256 count;
        vacated = new bytes32[](known.length);
        for (uint256 i; i < known.length; ++i) {
            if (!_hasOwner(known[i])) vacated[count++] = known[i];
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
    function simulateColdkeySwap(bytes32 validatorHotkey, bytes32 destination) external returns (bool) {
        MockStaking staking = MockStaking(STAKING_PRECOMPILE);
        if (_hasOwner(destination) || staking.ownerOf(validatorHotkey) == destination) return false;
        staking.simulateColdkeySwap(staking.ownerOf(validatorHotkey), destination, NETUID1, handler.knownHotkeys());
        return true;
    }

    function assertAttestedStakeRestsOnOwnedHotkeys() external view {
        (bytes32[] memory attested,) = registry.getValidators(NETUID1);
        VaultReads.Slot[] memory slots = vault.recordedSlots(TOKEN1);
        for (uint256 j; j < attested.length; ++j) {
            for (uint256 i; i < slots.length; ++i) {
                if (slots[i].attested != attested[j] || slots[i].tracked == 0) continue;
                assertTrue(_hasOwner(slots[i].stakedUnder), "attested stake rests on an ownerless hotkey");
            }
        }
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract HotkeySwapInvariantTest is HotkeySwapCampaignSetup {
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

contract HotkeySwapCampaignPathsTest is HotkeySwapCampaignSetup {
    function test_ReusedAttestedHotkeyAfterARetiredHotkey_ResolvesWithoutARepublish() public {
        handler.swapToFreshHotkey(0, 1, true);
        _assertSharedInvariants();
        handler.rebalance();
        _assertSharedInvariants();
        handler.drainSlot(0, 0);
        _assertSharedInvariants();
        assertEq(handler.drains(), 1, "the first slot is emptied on its successor hotkey");
        handler.swapToFreshHotkey(0, 2, true);
        _assertSharedInvariants();
        handler.swapOntoVacatedHotkey(1, 0, true);
        _assertSharedInvariants();
        assertEq(handler.reuseSwaps(), 1, "the second validator takes the vacated first hotkey");
        assertEq(handler.validatorHotkeys(1), hotkey1, "which is the first validator's attested hotkey");

        handler.rebalance();
        _assertSharedInvariants();

        assertEq(handler.rebalances(), 2, "the rebalance succeeds without a new attestation");
        assertEq(
            vault.recordedSlots(TOKEN1)[0].stakedUnder,
            handler.validatorHotkeys(0),
            "the emptied slot follows the validator's current hotkey"
        );
        _assertSharedInvariants();
    }

    function test_ParkedPartialExit_IsMeasuredOnTheParkingHotkey() public {
        handler.swapToFreshHotkey(0, 1, true);
        _assertSharedInvariants();
        handler.swapToFreshHotkey(0, 2, true);
        _assertSharedInvariants();
        assertTrue(lens.isBackingIntact(TOKEN1), "two unobserved hotkey swaps resolve on the staking list");
        _sweepDuringCrash(NETUID1, handler.validatorHotkeys(0));
        handler.syncBacking();
        vm.warp(lens.writeOffDeadline(TOKEN1));
        handler.syncBacking();
        _assertSharedInvariants();
        assertTrue(vault.awaitingAttestation(TOKEN1), "a swept slot's write-off parks the position");
        assertEq(_parkedStake(NETUID1), 33_335_000_000, "with the unswept 3333- and 3334-bps slots of 50 alpha parked");
        bytes32 recipient = keccak256(abi.encode(alice));
        uint256 before = _getStakeForColdkey(vault.parkingHotkey(), recipient, NETUID1);

        handler.unwrap(0, vault.balanceOf(alice, TOKEN1) / 4);
        _assertSharedInvariants();

        assertEq(handler.alphaExits(), 1, "the parked position pays the alpha exit");
        assertEq(handler.lastAlphaPaid(), 8_333_750_000, "a quarter of the 33.335 parked alpha");
        assertEq(
            handler.lastAlphaPaid(),
            _getStakeForColdkey(vault.parkingHotkey(), recipient, NETUID1) - before,
            "as the recipient's increase on the parking hotkey"
        );
    }

    function test_HandlerReachesEverySuccessPath() public {
        handler.wrap(1, 100, 0);
        _assertSharedInvariants();
        handler.unwrap(0, 1e18);
        _assertSharedInvariants();
        handler.unwrapForTao(0, 1e18);
        _assertSharedInvariants();
        handler.drainSlot(1, 2);
        _assertSharedInvariants();
        handler.swapToFreshHotkey(2, 7, false);
        _assertSharedInvariants();
        handler.swapToFreshHotkey(2, 8, true);
        _assertSharedInvariants();
        handler.swapOntoVacatedHotkey(0, 0, true);
        _assertSharedInvariants();
        handler.syncBacking();
        _assertSharedInvariants();
        handler.swapColdkey(0, 5);
        _assertSharedInvariants();
        handler.republish(3);
        _assertSharedInvariants();
        handler.rebalance();
        _assertSharedInvariants();
        uint256 owed = trackedBacking();
        handler.accrueEmissions(3);
        _assertSharedInvariants();
        assertEq(lens.locatedStake(TOKEN1), owed + 3e9, "emissions raise the located backing by 3 alpha");

        assertEq(handler.wraps(), 1, "a deposit wraps");
        assertEq(handler.alphaExits(), 1, "an alpha exit pays");
        assertEq(handler.taoExits(), 2, "a TAO exit and the masked drain both pay");
        assertEq(handler.drains(), 1, "a masked TAO exit empties one slot");
        assertEq(handler.freshSwaps(), 2, "a validator's hotkey swaps per subnet and across subnets");
        assertEq(handler.reuseSwaps(), 1, "a validator takes a vacated hotkey");
        assertEq(handler.syncs(), 1, "a sync records the unobserved hotkey swap");
        assertEq(handler.coldkeySwaps(), 1, "an operator moves to a fresh coldkey");
        assertEq(handler.republishes(), 1, "the registry publishes the validators' current hotkeys");
        assertEq(handler.rebalances(), 1, "the rebalance lands the new set");
        _assertSharedInvariants();
    }
}
