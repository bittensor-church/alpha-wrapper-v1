// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IStaking, MAX_STAKING_HOTKEYS, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { IValidatorRegistry, MAX_VALIDATORS } from "../interfaces/IValidatorRegistry.sol";
import { IAddressMapping, ADDRESS_MAPPING_PRECOMPILE } from "../interfaces/IAddressMapping.sol";
import { ISubnet, SUBNET_PRECOMPILE } from "../interfaces/ISubnet.sol";
import { VaultMath } from "./VaultMath.sol";
import {
    BackingShortfall, NoValidatorFound, AlphaTransfersDisabled,
    SubnetInDissolutionBlackoutPeriod, ValidatorSetMalformed, ValidatorSetTooLarge
} from "../VaultErrors.sol";

library VaultReads {
    uint256 internal constant NO_SHORT_SLOT = type(uint256).max;
    /// @dev Frozen with no deadline until recovery is declared.
    uint256 internal constant UNDECLARED_SHORTFALL = type(uint256).max;
    /// @dev Half the cap: every move and exit a clone signs pays the chain's walk of its whole list.
    uint256 private constant REPLACEMENT_LIST_LENGTH = MAX_STAKING_HOTKEYS / 2;

    function coldkeyOf(address evmAddress) internal view returns (bytes32) {
        return IAddressMapping(ADDRESS_MAPPING_PRECOMPILE).addressMapping(evmAddress);
    }

    function ownedBy(bytes32 hotkey, bytes32 coldkey) internal view returns (bool) {
        (bool exists, bytes32 owner) = IStaking(STAKING_PRECOMPILE).getHotkeyOwner(hotkey);
        return exists && owner == coldkey;
    }

    function lockedAlphaOf(bytes32 coldkey, uint16 netuid) internal view returns (uint256 lockedAlpha) {
        (,, lockedAlpha,,) = IStaking(STAKING_PRECOMPILE).getColdkeyLock(coldkey, netuid);
    }

    function stakingHotkeyCount(bytes32 coldkey) internal view returns (uint64 total) {
        (, total) = IStaking(STAKING_PRECOMPILE).getStakingHotkeys(coldkey, 0, 1);
    }

    /// @dev The last entry is kept for the parking hotkey, so recovery can always park.
    function stakingListAdmits(bytes32 coldkey, bytes32 hotkey, uint16 netuid, bytes32 parking) internal view returns (bool) {
        if (hotkey == parking || IStaking(STAKING_PRECOMPILE).getStake(hotkey, coldkey, netuid) != 0) return true;
        return stakingHotkeyCount(coldkey) + 2 <= MAX_STAKING_HOTKEYS;
    }

    function cloneReplacementOpen(bytes32 coldkey) internal view returns (bool) {
        return stakingHotkeyCount(coldkey) >= REPLACEMENT_LIST_LENGTH;
    }

    /// @dev One attestation: the target hotkeys and their basis-point weights.
    struct ValidatorSet { bytes32[] hotkeys; uint16[] weights; }

    function attestedSetOf(IValidatorRegistry registry, uint16 netuid) internal view returns (ValidatorSet memory set) {
        (bytes32[] memory hotkeys, uint16[] memory weights) = registry.getValidators(netuid);
        if (hotkeys.length == 0) revert NoValidatorFound();
        if (hotkeys.length > MAX_VALIDATORS) revert ValidatorSetTooLarge(hotkeys.length);
        if (hotkeys.length != weights.length) revert ValidatorSetMalformed();
        set = ValidatorSet({ hotkeys: hotkeys, weights: weights });
    }

    function stakesUnder(bytes32[] memory hotkeys, bytes32 coldkey, uint16 netuid) internal view returns (uint256[] memory balances) {
        balances = new uint256[](hotkeys.length);
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        for (uint256 i; i < hotkeys.length;) {
            balances[i] = staking.getStake(hotkeys[i], coldkey, netuid);
            unchecked { ++i; }
        }
    }

    /// @dev The counter identifies generations; migrations may rewrite the registration block.
    function _subnetState(uint256 tokenId) private view returns (bool ownGeneration, bool registered, bool dissolving) {
        uint16 netuid = VaultMath.netuidOf(tokenId);
        ISubnet subnet = ISubnet(SUBNET_PRECOMPILE);
        ownGeneration = subnet.getRegisteredSubnetCounter(netuid) == VaultMath.generationOf(tokenId);
        registered = subnet.getNetworkRegistrationBlock(netuid) != 0; dissolving = subnet.isSubnetDissolving(netuid);
    }

    /// @dev Whether the token's generation is gone; reverts while it is still being cleaned up.
    function isDissolved(uint256 tokenId) internal view returns (bool) {
        (bool ownGeneration, bool registered, bool dissolving) = _subnetState(tokenId);
        if (ownGeneration && dissolving) revert SubnetInDissolutionBlackoutPeriod();
        return !ownGeneration || !registered;
    }

    /// @dev Alpha balances are in flux from the start of dissolution on.
    function isDissolvingOrDissolved(uint256 tokenId) internal view returns (bool) {
        (bool ownGeneration, bool registered, bool dissolving) = _subnetState(tokenId);
        return dissolving || !ownGeneration || !registered;
    }

    function isDissolving(uint16 netuid) internal view returns (bool) {
        return ISubnet(SUBNET_PRECOMPILE).isSubnetDissolving(netuid);
    }

    function requireNotDissolving(uint16 netuid) internal view {
        if (isDissolving(netuid)) revert SubnetInDissolutionBlackoutPeriod();
    }

    /// @dev A transfer the chain will refuse burns every unit of gas forwarded to it; refuse it here.
    function requireTransfersEnabled(uint16 netuid) internal view {
        (,,,,,,,,, bool transfersEnabled,,) = ISubnet(SUBNET_PRECOMPILE).getSubnetCapacityConfig(netuid);
        if (!transfersEnabled) revert AlphaTransfersDisabled(netuid);
    }

    /// @dev TAO arriving during/after dissolution backs redemptions, not the claim index.
    function indexableTao(uint256 tokenId, uint256 balance, uint256 reserved) internal view returns (uint256) {
        uint256 newTao = VaultMath.unreservedTao(balance, reserved);
        if (newTao == 0) return 0;
        if (isDissolvingOrDissolved(tokenId)) return 0;
        return newTao;
    }

    /// @dev During recovery, only the parking slot carries the pooled tracked obligation.
    struct Slot { bytes32 attested; bytes32 stakedUnder; uint256 tracked; }

    struct Backing {
        bytes32[] hotkeys;
        uint256[] balances;
        bool[] short;
        uint256 total;
    }

    function attestedOf(Slot[] memory slots) internal pure returns (bytes32[] memory attested) {
        attested = new bytes32[](slots.length);
        for (uint256 i; i < slots.length;) { attested[i] = slots[i].attested; unchecked { ++i; } }
    }

    /// @dev Accepted accounting dust; smaller discrepancies do not start recovery.
    uint256 internal constant TRACKED_SLACK_RAO = 1e3;

    function hotkeySuccessor(bytes32 hotkey, uint16 netuid) internal view returns (bytes32) {
        (bool exists, bytes32 successor) = IStaking(STAKING_PRECOMPILE).getHotkeySuccessor(hotkey, netuid);
        if (!exists) return bytes32(0);
        return successor;
    }

    function stakedUnderOf(Slot[] memory slots) internal pure returns (bytes32[] memory hotkeys) {
        hotkeys = new bytes32[](slots.length);
        for (uint256 i; i < hotkeys.length;) { hotkeys[i] = slots[i].stakedUnder; unchecked { ++i; } }
    }

    function firstShortOf(bool[] memory short) internal pure returns (uint256) {
        for (uint256 i; i < short.length;) { if (short[i]) return i; unchecked { ++i; } }
        return NO_SHORT_SLOT;
    }

    function requireIntact(Slot[] memory slots, Backing memory backing, uint16 netuid) internal pure {
        uint256 shortIndex = firstShortOf(backing.short);
        if (shortIndex != NO_SHORT_SLOT) {
            revert BackingShortfall(netuid, slots[shortIndex].stakedUnder, slots[shortIndex].tracked);
        }
    }

    function coversTracked(uint256 stake, uint256 tracked) internal pure returns (bool) {
        return stake + TRACKED_SLACK_RAO >= tracked;
    }
}
