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

/// @notice Read-only quotes for AlphaVault positions. Nothing here moves funds.
/// @dev A quote uses the vault's own math, but it is not a promise that the matching
///      transaction will succeed. Check that `vault()` is the vault you trust: a lens
///      naming the right vault can still be the wrong build.
///      A contract reading this from inside a vault callback sees half-finished state.
contract AlphaVaultLens {
    /// @dev One pass of everything a backing read needs, so each entry point hits the vault
    ///      and the precompiles once. No clone yet means no `slots` and no `backing`.
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

    /// @notice Alpha backing every share of `tokenId`.
    /// @dev Reverts on missing alpha or a loss on file, exactly as wrap and unwrap do, so a quote
    ///      never prices stake the vault cannot pay out. Also reverts if the backing is
    ///      conviction-locked. Dissolution is converting the alpha to TAO, so the coverage check
    ///      is skipped there rather than reporting the drain as missing.
    function totalStake(uint256 tokenId) public view returns (uint256) {
        if (_shortSince(tokenId) != 0) revert ShortfallOnFile();
        return _intactStakeOf(_readBacking(tokenId));
    }

    /// @notice Alpha the vault can find right now. Never reverts, so use it to show a position
    ///         that `totalStake` refuses to price.
    function locatedStake(uint256 tokenId) external view returns (uint256) { return _readBacking(tokenId).backing.total; }

    /// @notice How much of the recorded obligation is nowhere to be found, summed over every slot.
    /// @dev A size, not a verdict: zero here does not mean the position is usable. Slots are summed,
    ///      so a slot running an emissions surplus can mask another slot's deficit, and unlike
    ///      `isBackingIntact` this allows no per-slot dust tolerance. `isBackingIntact` answers the
    ///      coverage question; `totalStake` reverting is the full answer to whether the vault will
    ///      price the position.
    ///      Dust still sitting on a recorded key counts as found, even when the vault cannot collect
    ///      it and eventually writes it off.
    function missingStake(uint256 tokenId) external view returns (uint256) {
        BackingRead memory read = _readBacking(tokenId);
        uint256 expected;
        for (uint256 i; i < read.slots.length; ++i) { expected += read.slots[i].tracked; }
        return expected > read.backing.total ? expected - read.backing.total : 0;
    }

    /// @notice Where the backing sits: each recorded slot's key and the alpha on it.
    /// @dev Keys are followed one hotkey-swap hop, which is what a TAO exit does before selling,
    ///      so `keys[i]` is the key slot `i` would sell from. A slot flagged in `short` makes
    ///      that exit revert.
    function resolvedBacking(uint256 tokenId) external view returns (VaultReads.Backing memory backing) {
        address clone = vault.subnetClone(tokenId);
        if (clone == address(0)) return backing;
        return VaultReads.resolveBacking(
            vault.recordedSlots(tokenId), VaultReads.coldkeyOf(clone), VaultMath.netuidOf(tokenId));
    }

    /// @notice The keys the vault last recorded, without following any swap made since.
    function lastSeenHotkeys(uint256 tokenId) external view returns (bytes32[] memory) {
        return VaultReads.activesOf(vault.recordedSlots(tokenId));
    }

    /// @notice True when every recorded slot is covered and no loss is on file.
    /// @dev One of the gates wrap, unwrap and the value quotes apply, not all of them: backing under
    ///      a conviction lock reverts those calls with `LockedBacking` while this still reads true.
    ///      Says nothing either about who owns the hotkeys.
    ///      Checks each slot on its own, with a small dust tolerance, so this is not
    ///      `missingStake(tokenId) == 0`: a surplus on one slot cannot cover another slot's deficit,
    ///      and a fully recovered position still reads false until `syncBacking` clears the loss
    ///      from the record.
    ///      A dissolving or dissolved position skips the coverage check, so it reads true unless a
    ///      loss is already on file.
    function isBackingIntact(uint256 tokenId) external view returns (bool) {
        if (_shortSince(tokenId) != 0) return false;
        return VaultReads.firstShortOf(_readBacking(tokenId).backing.short) == VaultReads.NO_SHORT_SLOT;
    }

    /// @notice When the vault may give up on missing alpha and write it off.
    /// @return deadline Zero when nothing is missing. `VaultReads.UNDECLARED_SHORTFALL` (max uint256)
    ///         when alpha is missing but no one has called `syncBacking` to start the clock.
    ///         Otherwise the timestamp from which `syncBacking` may write the loss off.
    /// @dev Reaching the deadline only permits the write-off; someone must still call `syncBacking`,
    ///      and recovering the alpha first clears it. Alpha below the chain's stake floor cannot be
    ///      collected, so a write-off can still land after a full recovery attempt.
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

    /// @dev Dissolution turns alpha into TAO, so a falling alpha balance there is not missing backing.
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

    /// @dev Dissolution is converting the alpha away, so there is no lock left to check.
    function _intactStakeOf(BackingRead memory read) private view returns (uint256) {
        VaultReads.requireIntact(read.slots, read.backing, read.netuid);
        if (read.clone != address(0) && !read.alphaInFlux && VaultReads.lockedAlphaOf(read.coldkey, read.netuid) != 0) {
            revert LockedBacking();
        }
        return read.backing.total;
    }

    /// @notice Alpha per share, scaled by 1e18, counting the virtual share and asset the vault
    ///         prices against.
    /// @dev Returns zero after a complete write-off. Reverts when backing is positive but too small
    ///      to show at this scale; `previewUnwrap` can still price a large enough burn.
    function sharePrice(uint256 tokenId) external view returns (uint256) {
        _requireCurrentRegistration(tokenId);
        uint256 supply = vault.totalSupply(tokenId);
        if (supply == 0) revert NoSharesOutstanding();
        uint256 stake = totalStake(tokenId);
        // Without this the virtual asset would imply the shares still hold value after a full write-off.
        if (stake == 0) return 0;
        uint256 price = VaultMath.assetsFor(stake, supply, VaultMath.SHARE_PRICE_SCALE);
        if (price == 0) revert SharePriceBelowPrecision();
        return price;
    }

    /// @notice Shares that depositing `assets` alpha RAO would mint right now.
    /// @dev Reverts while the position is parked, as `wrap` does. The real mint can differ slightly,
    ///      so set `minSharesOut` from this with the tolerance you accept.
    function previewWrap(uint256 tokenId, uint256 assets) external view returns (uint256) {
        _requireCurrentRegistration(tokenId);
        if (vault.awaitingAttestation(tokenId)) revert Parked();
        return VaultMath.sharesFor(totalStake(tokenId), vault.totalSupply(tokenId), assets);
    }

    /// @notice What burning `shares` pays: alpha RAO on a live subnet, TAO wei on a dissolved one.
    /// @dev Leaves out claimable TAO and does not quote `unwrapForTao`. Chain rounding can credit a
    ///      little less alpha than quoted, and ownership, transfer, size and validator checks still
    ///      apply at execution.
    ///      A zero quote is not permission to accept zero: passing `minAlphaOut = 0` is the caller's
    ///      own decision. A dissolved position with no TAO left to share quotes zero, and the exit
    ///      itself reverts.
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

    /// @notice TAO `account` can claim for `tokenId`, in wei, counting TAO that has arrived but is
    ///         not yet indexed. Floored to whole RAO, which is what `claimTao` pays.
    function claimableTaoOf(address account, uint256 tokenId) external view returns (uint256) {
        return _claimableTaoOf(account, tokenId);
    }

    /// @notice `claimableTaoOf` for several positions in one call.
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
