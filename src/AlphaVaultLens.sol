// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVault } from "./AlphaVault.sol";
import { VaultMath } from "./libraries/VaultMath.sol";
import { VaultReads } from "./libraries/VaultReads.sol";
import {
    LockedBacking, NoSharesOutstanding, Parked,
    SharePriceBelowPrecision, ShortfallOnFile,
    SubnetDissolved, ZeroAddress
} from "./VaultErrors.sol";

/// @notice Quotes and backing reads for AlphaVault.
/// @dev Use a trusted build. Quotes do not guarantee execution; callback reads may see incomplete state.
contract AlphaVaultLens {
    /// @dev Cached backing data. Without a clone, `slots` and `backing` are empty.
    struct BackingRead {
        address clone;
        uint16 netuid;
        bytes32 coldkey;
        bool alphaInFlux;
        VaultReads.Slot[] slots;
        VaultReads.Backing backing;
    }

    AlphaVault public immutable vault;

    constructor(AlphaVault _vault) {
        if (address(_vault) == address(0)) revert ZeroAddress();
        vault = _vault;
    }

    /// @notice Alpha backing `tokenId`, in RAO.
    /// @dev Rejects recorded losses. Checks coverage and locks only on live, non-dissolving positions.
    function totalStake(uint256 tokenId) public view returns (uint256) {
        if (_shortSince(tokenId) != 0) revert ShortfallOnFile();
        return _intactStakeOf(_readBacking(tokenId));
    }

    /// @notice Located alpha in RAO, even when backing is short or locked.
    function locatedStake(uint256 tokenId) external view returns (uint256) { return _readBacking(tokenId).backing.total; }

    /// @notice Missing alpha in RAO. Zero during and after dissolution.
    /// @dev Counts dust and offsets deficits with surpluses; zero does not imply intact backing.
    function missingStake(uint256 tokenId) external view returns (uint256) {
        BackingRead memory read = _readBacking(tokenId);
        uint256 expected;
        for (uint256 i; i < read.slots.length; ++i) { expected += read.slots[i].tracked; }
        return expected > read.backing.total ? expected - read.backing.total : 0;
    }

    /// @notice Backing keys and alpha RAO, following at most one swap per slot.
    /// @dev TAO exits sell from `keys`; any `short` flag blocks the exit.
    function resolvedBacking(uint256 tokenId) external view returns (VaultReads.Backing memory backing) {
        address clone = vault.subnetClone(tokenId);
        if (clone == address(0)) return backing;
        return VaultReads.resolveBacking(
            vault.recordedSlots(tokenId), VaultReads.coldkeyOf(clone), VaultMath.netuidOf(tokenId));
    }

    /// @notice Recorded active hotkeys, without resolving later swaps.
    function lastSeenHotkeys(uint256 tokenId) external view returns (bytes32[] memory) {
        return VaultReads.activesOf(vault.recordedSlots(tokenId));
    }

    /// @notice Whether backing passes coverage and recorded-loss checks.
    /// @dev Allows per-slot dust; skips coverage during/after dissolution. Ignores locks and ownership.
    function isBackingIntact(uint256 tokenId) external view returns (bool) {
        if (_shortSince(tokenId) != 0) return false;
        return VaultReads.firstShortOf(_readBacking(tokenId).backing.short) == VaultReads.NO_SHORT_SLOT;
    }

    /// @notice Earliest time `syncBacking` may write off a recorded loss.
    /// @return deadline Recorded deadline, max uint256 for an undeclared shortfall, or zero if intact.
    /// @dev Expiry alone does not clear the loss.
    function writeOffDeadline(uint256 tokenId) external view returns (uint256 deadline) {
        uint64 shortSince = _shortSince(tokenId);
        if (shortSince != 0) return shortSince + vault.recoveryWindow();
        if (VaultReads.firstShortOf(_readBacking(tokenId).backing.short) != VaultReads.NO_SHORT_SLOT) {
            deadline = VaultReads.UNDECLARED_SHORTFALL;
        }
    }

    function _readBacking(uint256 tokenId) private view returns (BackingRead memory read) {
        read.netuid = VaultMath.netuidOf(tokenId); read.clone = vault.subnetClone(tokenId);
        if (read.clone == address(0)) return read;
        _locateBacking(read, tokenId, VaultReads.isDissolvingOrDissolved(tokenId));
    }

    function _locateBacking(BackingRead memory read, uint256 tokenId, bool alphaInFlux) private view {
        read.coldkey = VaultReads.coldkeyOf(read.clone); read.alphaInFlux = alphaInFlux;
        if (alphaInFlux) {
            bytes32[] memory keys = VaultReads.activesOf(vault.recordedSlots(tokenId));
            read.backing.total = VaultMath.sumBalances(VaultReads.fetchBalances(keys, read.coldkey, read.netuid));
            return;
        }
        read.slots = vault.recordedSlots(tokenId);
        read.backing = VaultReads.resolveBacking(read.slots, read.coldkey, read.netuid);
    }

    function _intactStakeOf(BackingRead memory read) private view returns (uint256) {
        VaultReads.requireIntact(read.slots, read.backing, read.netuid);
        if (read.clone != address(0) && !read.alphaInFlux && VaultReads.lockedAlphaOf(read.coldkey, read.netuid) != 0) {
            revert LockedBacking();
        }
        return read.backing.total;
    }

    /// @notice Alpha per share, scaled by 1e18, including virtual offsets.
    /// @dev Zero backing quotes zero; positive backing below precision reverts. Use `previewUnwrap` for a burn.
    function sharePrice(uint256 tokenId) external view returns (uint256) {
        _requireCurrentRegistration(tokenId);
        uint256 supply = vault.totalSupply(tokenId);
        if (supply == 0) revert NoSharesOutstanding();
        uint256 stake = totalStake(tokenId);
        // Ignore the virtual asset after a full write-off.
        if (stake == 0) return 0;
        uint256 price = VaultMath.assetsFor(stake, supply, VaultMath.SHARE_PRICE_SCALE);
        if (price == 0) revert SharePriceBelowPrecision();
        return price;
    }

    /// @notice Estimated shares for depositing `assets` alpha RAO.
    /// @dev Reverts while awaiting attestation. Actual shares may differ; set `minSharesOut`.
    function previewWrap(uint256 tokenId, uint256 assets) external view returns (uint256) {
        _requireCurrentRegistration(tokenId);
        if (vault.awaitingAttestation(tokenId)) revert Parked();
        return VaultMath.sharesFor(totalStake(tokenId), vault.totalSupply(tokenId), assets);
    }

    /// @notice Estimated exit payout: live alpha RAO or dissolved TAO wei.
    /// @dev Excludes claims and market sales. Rounding may reduce alpha; zero quotes may still revert on exit.
    function previewUnwrap(uint256 tokenId, uint256 shares) external view returns (uint256 alpha, uint256 tao) {
        if (shares == 0) return (0, 0);
        BackingRead memory read;
        read.netuid = VaultMath.netuidOf(tokenId); read.clone = vault.subnetClone(tokenId);
        if (read.clone == address(0)) return (0, 0);
        uint256 supply = vault.totalSupply(tokenId);
        if (supply == 0) return (0, 0);

        if (VaultReads.isDissolved(tokenId)) {
            uint256 backing = VaultMath.unreservedTao(read.clone.balance, vault.taoLiability(tokenId));
            if (backing == 0) return (0, 0);
            return (0, VaultMath.toNativeQuantum(VaultMath.proRata(backing, shares, supply)));
        }

        if (_shortSince(tokenId) != 0) revert ShortfallOnFile();
        // Passing the dissolution check means this generation is live and its alpha is not in flux.
        _locateBacking(read, tokenId, false);

        return (VaultMath.assetsFor(_intactStakeOf(read), supply, shares), 0);
    }

    /// @notice Claimable TAO in wei, including pending accrual, rounded down to whole RAO.
    function claimableTaoOf(address account, uint256 tokenId) external view returns (uint256) {
        return _claimableTaoOf(account, tokenId);
    }

    /// @notice Claimable TAO for each token ID, in input order.
    function batchClaimableTaoOf(address account, uint256[] calldata tokenIds) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) { amounts[i] = _claimableTaoOf(account, tokenIds[i]); }
    }

    function _claimableTaoOf(address account, uint256 tokenId) private view returns (uint256) {
        uint256 liability = vault.taoLiability(tokenId);
        (uint256 indexIncrease, uint256 liabilityIncrease) = _previewSyncTao(tokenId, liability);
        uint256 index = vault.cumulativeTaoPerShare(tokenId) + indexIncrease;
        uint256 backing = liability + liabilityIncrease;
        uint256 entitlement = vault.claimableTao(tokenId, account) + _pendingAt(account, tokenId, index);
        return VaultMath.toNativeQuantum(VaultMath.backedEntitlement(entitlement, backing));
    }

    function _shortSince(uint256 tokenId) private view returns (uint64 shortSince) { (shortSince,) = vault.recovery(tokenId); }

    function _requireCurrentRegistration(uint256 tokenId) private view {
        if (VaultReads.isDissolved(tokenId)) revert SubnetDissolved();
    }

    function _previewSyncTao(uint256 tokenId, uint256 liability) private view returns (uint256, uint256) {
        address clone = vault.subnetClone(tokenId);
        if (clone == address(0)) return (0, 0);
        uint256 newTao = VaultReads.indexableTao(tokenId, clone.balance, liability);
        if (newTao == 0) return (0, 0);
        return VaultMath.syncAmounts(newTao, vault.totalSupply(tokenId));
    }

    function _pendingAt(address account, uint256 tokenId, uint256 index) private view returns (uint256) {
        return VaultMath.pendingTao(
            VaultMath.earnedAt(vault.balanceOf(account, tokenId), index), vault.taoIndexDebt(tokenId, account));
    }
}
