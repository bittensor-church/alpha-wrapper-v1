// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice The vault's events, and the errors its linked libraries and clone factory raise on its behalf,
///         so callers decode them from the vault ABI.
interface IAlphaVaultAbi {
    event Deposited(address indexed user, uint256 indexed tokenId, bytes32 indexed hotkey, uint256 assets, uint256 shares);
    /// @dev `alphaOut` is observed recipient credit in alpha RAO, not the requested transfer.
    event Unwrapped(
        address indexed user, uint256 indexed tokenId, bytes32 destinationColdkey, uint256 shares, uint256 alphaOut);
    /// @dev `taoOut` is native TAO in EVM wei.
    event DissolvedSubnetUnwrapped(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 taoOut);
    /// @dev Weight-alignment moves only; excludes consolidation and payout-gather hops.
    event Rebalanced(uint256 indexed tokenId, bytes32 indexed fromHotkey, bytes32 indexed toHotkey, uint256 amount);
    event SubnetProxyCreated(uint256 indexed tokenId, address clone);
    /// @dev The token's position now lives on `clone`; whatever strangers left on `previous` stays there.
    event SubnetCloneReplaced(uint256 indexed tokenId, address indexed previous, address clone);
    event MailboxCreated(address indexed user, uint256 indexed netuid, address mailbox);
    /// @dev `sharesBurned` is the caller's burn and `sharesRefunded` the shares minted back for alpha the
    ///      sale left unsold; a full burn's empty-vault refund rate can exceed the burn. `taoOut` is EVM wei.
    event UnwrappedForTao(
        address indexed user, uint256 indexed tokenId, uint256 sharesBurned,
        uint256 sharesRefunded, uint256 alphaSold, uint256 taoOut);
    event MailboxAlphaSoldForTao(address indexed user, uint256 indexed netuid, uint256 alpha, uint256 taoOut);
    event MailboxAlphaReclaimed(address indexed user, uint256 indexed netuid, bytes32 destinationColdkey, uint256 alpha);
    /// @dev `amount` is native TAO in EVM wei.
    event MailboxTaoReclaimed(address indexed user, uint256 indexed netuid, uint256 amount);
    /// @dev `amount` is native TAO in EVM wei.
    event TaoClaimed(address indexed user, uint256 indexed tokenId, address indexed recipient, uint256 amount);
    /// @dev The window starts once located backing above the floor sits on parking; smaller piles can stay behind.
    event BackingShortfallDeclared(uint256 indexed tokenId, uint256 expected, uint256 located);
    event BackingShortfallCleared(uint256 indexed tokenId);
    /// @dev Loss falls on holders at write-off; later recovery belongs to holders at recovery time.
    event BackingWrittenOff(uint256 indexed tokenId, uint256 expected, uint256 located);
    /// @dev The position rests on the parking hotkey until an attestation newer than `registryNonce` lands.
    ///      A zero `registryNonce` means no shares remained, so deposits stay open.
    event BackingParked(uint256 indexed tokenId, uint256 backing, uint256 registryNonce);
    /// @dev Ends the parking announced at `registryNonce`: a newer attestation landed, or no shares remain.
    event ParkingReleased(uint256 indexed tokenId, uint256 registryNonce);
    /// @dev `recoverStray` moved the vault's alpha from `source` onto `destination`.
    event BackingRecovered(uint256 indexed tokenId, bytes32 indexed source, bytes32 indexed destination, uint256 amount);
    /// @dev A sync during recovery moved returns from recorded hotkeys onto the parking hotkey.
    event BackingCollected(uint256 indexed tokenId, uint256 amount);
    /// @dev Outside recovery, the record moved slot `slot` from `fromHotkey` to `toHotkey`; a zero `fromHotkey`
    ///      is a new slot.
    event SlotRelocated(uint256 indexed tokenId, uint256 slot, bytes32 indexed fromHotkey, bytes32 indexed toHotkey);

    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);
    error ConsolidationBelowFloor();
    error GatherBelowFloor();
    error DepositTooSmall();
    error CloneProtectionFailed(address clone);
    error CloneContaminated(address candidate);
    /// @dev Two attested entries would share one backing hotkey; a registry update must resolve the collision.
    error SwappedHotkeyStillAttested();
    /// @dev The clone's staking list cannot take another hotkey; `replaceClone` moves the position to a fresh one.
    error StakingListFull();
}
