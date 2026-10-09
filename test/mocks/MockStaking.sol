// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { VaultMath } from "src/libraries/VaultMath.sol";
import { MockAlpha } from "./MockAlpha.sol";
import { MockSubnetPrecompile } from "./MockSubnetPrecompile.sol";
import { ALPHA_PRECOMPILE } from "src/interfaces/IAlpha.sol";
import { SUBNET_PRECOMPILE } from "src/interfaces/ISubnet.sol";

/// @dev Fixtures must seed minimums after `vm.etch`, which copies code but not storage.
uint256 constant CHAIN_MIN_STAKE = 2e6;

uint256 constant CHAIN_MIN_TRANSFER = 1e5;

uint256 constant CHAIN_NOMINATOR_MIN_STAKE = 20e6;

/// @dev Uses keccak256, not Frontier's blake2b. Every refusal consumes the forwarded gas and returns no data,
///      as a refused precompile dispatch does.
contract MockStaking {
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) private _stakes;
    uint256 public moveStakeRoundingLoss;
    uint256 public moveStakeResidual;
    uint256 public transferStakeRoundingLoss;
    bool public transferStakeReverts;
    uint256 private _chainMinStakeTao;

    uint256 private _chainMinTransferTao;

    function setTransferStakeReverts(bool v) external {
        transferStakeReverts = v;
    }

    function _fail() private pure {
        assembly {
            invalid()
        }
    }

    /// @dev Alpha per (coldkey, netuid) across hotkeys, the total the chain's lock checks read.
    mapping(bytes32 => mapping(uint256 => uint256)) public coldkeyAlpha;

    /// @dev Coldkeys with stake on (hotkey, netuid), so a hotkey swap can move every position, and hotkeys a
    ///      coldkey holds stake under on a netuid, so dissolution can clear them.
    mapping(bytes32 => mapping(uint256 => bytes32[])) private _stakers;
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) private _stakerSlot;
    mapping(bytes32 => mapping(uint256 => bytes32[])) private _positions;
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) private _positionSlot;

    function setStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amount) external {
        _writeStake(hotkey, coldkey, netuid, amount);
    }

    /// @dev The one path that writes stake. The chain stores alpha as u64 RAO.
    function _writeStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amount) private {
        require(amount <= type(uint64).max, "MockStaking: stake above u64");
        uint256 previous = _stakes[hotkey][coldkey][netuid];
        coldkeyAlpha[coldkey][netuid] = coldkeyAlpha[coldkey][netuid] + amount - previous;
        _stakes[hotkey][coldkey][netuid] = amount;
        if (previous == 0 && amount != 0) {
            _insert(_stakers[hotkey][netuid], _stakerSlot[hotkey], netuid, coldkey);
            _insert(_positions[coldkey][netuid], _positionSlot[coldkey], netuid, hotkey);
        } else if (previous != 0 && amount == 0) {
            _remove(_stakers[hotkey][netuid], _stakerSlot[hotkey], netuid, coldkey);
            _remove(_positions[coldkey][netuid], _positionSlot[coldkey], netuid, hotkey);
        }
    }

    function _insert(
        bytes32[] storage set,
        mapping(bytes32 => mapping(uint256 => uint256)) storage slots,
        uint256 netuid,
        bytes32 member
    ) private {
        set.push(member);
        slots[member][netuid] = set.length;
    }

    function _remove(
        bytes32[] storage set,
        mapping(bytes32 => mapping(uint256 => uint256)) storage slots,
        uint256 netuid,
        bytes32 member
    ) private {
        uint256 index = slots[member][netuid] - 1;
        bytes32 last = set[set.length - 1];
        set[index] = last;
        slots[last][netuid] = index + 1;
        set.pop();
        delete slots[member][netuid];
    }

    /// @dev Dissolution deletes every alpha position on the subnet.
    function clearPositions(bytes32 coldkey, uint256 netuid) external {
        bytes32[] memory hotkeys = _positions[coldkey][netuid];
        for (uint256 i; i < hotkeys.length; ++i) {
            _writeStake(hotkeys[i], coldkey, netuid, 0);
        }
    }

    function _addStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amount) private {
        _writeStake(hotkey, coldkey, netuid, _stakes[hotkey][coldkey][netuid] + amount);
    }

    function _senderColdkey() private view returns (bytes32) {
        return keccak256(abi.encodePacked("evm:", msg.sender));
    }

    /// @dev The precompile saturates amounts to u64.
    function _u64(uint256 amount) private pure returns (uint256) {
        return amount > type(uint64).max ? type(uint64).max : amount;
    }

    // Chain minimums use full-precision prices even when the EVM reader rounds to zero.
    function _belowTaoValue(uint256 amount, uint256 netuid, uint256 thresholdTao) private view returns (bool) {
        uint256 alphaPriceE18 = MockAlpha(ALPHA_PRECOMPILE).chainAlphaPrice(uint16(netuid));
        return (amount * alphaPriceE18) / VaultMath.ALPHA_PRICE_SCALE < thresholdTao;
    }

    function setChainMinStake(uint256 minStakeTao) external {
        _chainMinStakeTao = minStakeTao;
    }

    function setChainMinTransfer(uint256 minTransferTao) external {
        _chainMinTransferTao = minTransferTao;
    }

    function getDefaultMinStake() external view returns (uint256) {
        return _chainMinStakeTao;
    }

    /// @dev Every stake operation needs a live subnet.
    function _requireStakingOpen(uint256 netuid) private view {
        if (MockSubnetPrecompile(SUBNET_PRECOMPILE).getNetworkRegistrationBlock(uint16(netuid)) == 0) _fail();
    }

    function _requireTransfersEnabled(uint256 netuid) private view {
        (,,,,,,,,, bool transfersEnabled,,) =
            MockSubnetPrecompile(SUBNET_PRECOMPILE).getSubnetCapacityConfig(uint16(netuid));
        if (!transfersEnabled) _fail();
    }

    // --- Conviction locks -------------------------------------------------------------------------
    // The chain keys a lock by hotkey as well; only the coldkey-wide locked mass matters to the vault.

    /// @dev Locked mass per (coldkey, netuid) in alpha RAO, and the one hotkey the chain keys it to.
    mapping(bytes32 => mapping(uint256 => uint256)) public lockedAlpha;
    mapping(bytes32 => mapping(uint256 => bytes32)) public lockHotkey;
    mapping(bytes32 => bool) private _acceptsLockedAlpha;
    mapping(bytes32 => uint256) public rejectLockedAlphaCalls;

    function setLockedAlpha(bytes32 coldkey, uint256 netuid, bytes32 hotkey, uint256 amount) external {
        lockedAlpha[coldkey][netuid] = amount;
        lockHotkey[coldkey][netuid] = amount == 0 ? bytes32(0) : hotkey;
    }

    /// @dev Models the flag a coldkey swap copies onto an account with no stake.
    function setAcceptsLockedAlpha(bytes32 coldkey, bool accepts) external {
        _acceptsLockedAlpha[coldkey] = accepts;
    }

    function getRejectLockedAlpha(bytes32 coldkey) external view returns (bool) {
        return !_acceptsLockedAlpha[coldkey];
    }

    function getColdkeyLock(bytes32 coldkey, uint256 netuid)
        external
        view
        returns (bool exists, bytes32 hotkey, uint256 locked, uint128 conviction, bool perpetual)
    {
        locked = lockedAlpha[coldkey][netuid];
        return (locked != 0, lockHotkey[coldkey][netuid], locked, conviction, perpetual);
    }

    function setRejectLockedAlpha(bool enabled) external payable {
        bytes32 coldkey = _senderColdkey();
        _acceptsLockedAlpha[coldkey] = !enabled;
        rejectLockedAlphaCalls[coldkey]++;
    }

    /// @dev Unlocked alpha leaves first; whatever a transfer takes beyond it carries the lock along.
    function _carriedLock(bytes32 coldkey, uint256 netuid, uint256 amount) private view returns (uint256) {
        uint256 locked = lockedAlpha[coldkey][netuid];
        if (locked == 0) return 0;
        uint256 total = coldkeyAlpha[coldkey][netuid];
        uint256 available = total > locked ? total - locked : 0;
        if (amount <= available) return 0;
        uint256 excess = amount - available;
        return excess > locked ? locked : excess;
    }

    function _reduceLock(bytes32 coldkey, uint256 netuid, uint256 amount) private {
        uint256 locked = lockedAlpha[coldkey][netuid];
        lockedAlpha[coldkey][netuid] = locked > amount ? locked - amount : 0;
        if (lockedAlpha[coldkey][netuid] == 0) lockHotkey[coldkey][netuid] = bytes32(0);
    }

    /// @dev Checks shared by moves and transfers within one subnet, in the chain's order.
    function _requireMovable(
        bytes32 originHotkey,
        bytes32 destinationHotkey,
        bytes32 coldkey,
        uint256 netuid,
        uint256 amount
    ) private view {
        _requireStakingOpen(netuid);
        if (!_hasOwnerRecord(originHotkey) || !_hasOwnerRecord(destinationHotkey)) _fail();
        if (amount > _stakes[originHotkey][coldkey][netuid]) _fail();
        if (_belowTaoValue(amount, netuid, _chainMinTransferTao)) _fail();
    }

    function transferStake(
        bytes32 destination_coldkey,
        bytes32 hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable {
        amount = _u64(amount);
        if (transferStakeReverts) _fail();
        bytes32 origin = _senderColdkey();
        _requireMovable(hotkey, hotkey, origin, origin_netuid, amount);
        _requireTransfersEnabled(origin_netuid);
        uint256 carriedLock = _carriedLock(origin, origin_netuid, amount);
        if (carriedLock != 0) {
            if (!_acceptsLockedAlpha[destination_coldkey]) _fail();
            bytes32 destinationLockHotkey = lockHotkey[destination_coldkey][destination_netuid];
            if (destinationLockHotkey != bytes32(0) && destinationLockHotkey != hotkey) _fail();
            _reduceLock(origin, origin_netuid, carriedLock);
            lockHotkey[destination_coldkey][destination_netuid] = hotkey;
            lockedAlpha[destination_coldkey][destination_netuid] += carriedLock;
        }
        _writeStake(hotkey, origin, origin_netuid, _stakes[hotkey][origin][origin_netuid] - amount);
        uint256 credited = amount > transferStakeRoundingLoss ? amount - transferStakeRoundingLoss : 0;
        _addStake(hotkey, destination_coldkey, destination_netuid, credited);
    }

    function setTransferStakeRoundingLoss(uint256 loss) external {
        transferStakeRoundingLoss = loss;
    }

    function setMoveStakeRoundingLoss(uint256 loss) external {
        moveStakeRoundingLoss = loss;
    }

    /// @dev Fault injection with no chain counterpart: leave alpha at the source despite a successful move.
    function setMoveStakeResidual(uint256 residual) external {
        moveStakeResidual = residual;
    }

    bool public moveStakeReverts;

    function setMoveStakeReverts(bool v) external {
        moveStakeReverts = v;
    }

    function moveStake(
        bytes32 origin_hotkey,
        bytes32 destination_hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external payable {
        amount = _u64(amount);
        if (moveStakeReverts) _fail();
        bytes32 coldkey = _senderColdkey();
        _requireMovable(origin_hotkey, destination_hotkey, coldkey, origin_netuid, amount);
        uint256 moved = amount > moveStakeResidual ? amount - moveStakeResidual : 0;
        _writeStake(origin_hotkey, coldkey, origin_netuid, _stakes[origin_hotkey][coldkey][origin_netuid] - moved);
        _addStake(destination_hotkey, coldkey, destination_netuid, moved - moveStakeRoundingLoss);
    }

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256) {
        return _stakes[hotkey][coldkey][netuid];
    }

    /// @dev A chain hotkey swap moves every coldkey's position on `netuid` from one hotkey to the other.
    function moveHotkeyPositions(bytes32 fromHotkey, bytes32 toHotkey, uint256 netuid) external {
        bytes32[] memory stakers = _stakers[fromHotkey][netuid];
        for (uint256 i; i < stakers.length; ++i) {
            uint256 amount = _stakes[fromHotkey][stakers[i]][netuid];
            _writeStake(fromHotkey, stakers[i], netuid, 0);
            _addStake(toHotkey, stakers[i], netuid, amount);
        }
    }

    /// @dev Models a missing owner record, not deletion of the hotkey identifier or its stake.
    mapping(bytes32 => bool) public hotkeyDeleted;

    /// @dev The chain drops a hotkey from its owner's index when the record goes, and a restored
    ///      record rejoins the index of the owner it answers with.
    function setHotkeyDeleted(bytes32 hotkey, bool deleted) external {
        hotkeyDeleted[hotkey] = deleted;
        if (deleted) {
            _dropOwnedHotkey(hotkey);
        } else if (_hotkeyOwned[hotkey]) {
            _indexOwnedHotkey(ownerOf(hotkey), hotkey);
        }
    }

    /// @dev Seed owner presence separately from balances so tests can model ownerless stake.
    ///      A hotkey without an explicit owner is owned by a coldkey derived from its own name.
    mapping(bytes32 => bool) private _hotkeyOwned;
    mapping(bytes32 => bytes32) private _hotkeyOwner;

    function setHotkeyOwned(bytes32 hotkey, bool owned) external {
        if (owned) {
            _assignOwner(hotkey, ownerOf(hotkey));
        } else {
            _hotkeyOwned[hotkey] = false;
            _dropOwnedHotkey(hotkey);
        }
    }

    function setHotkeyOwner(bytes32 hotkey, bytes32 coldkey) external {
        _assignOwner(hotkey, coldkey);
    }

    /// @dev The one path that writes ownership, so the owner a hotkey answers with and the index of
    ///      owned hotkeys never disagree: the previous index entry goes, and a new one is recorded only
    ///      while the record is not deleted, since reseeding never restores a deleted record.
    function _assignOwner(bytes32 hotkey, bytes32 coldkey) private {
        _dropOwnedHotkey(hotkey);
        _hotkeyOwned[hotkey] = true;
        _hotkeyOwner[hotkey] = coldkey;
        if (!hotkeyDeleted[hotkey]) _indexOwnedHotkey(coldkey, hotkey);
    }

    /// @dev Every stake operation the chain accepts touches hotkeys that have an owner record.
    function _hasOwnerRecord(bytes32 hotkey) private view returns (bool) {
        return _hotkeyOwned[hotkey] && !hotkeyDeleted[hotkey];
    }

    /// @dev The owner a hotkey answers with while it has one, ignoring a deleted record.
    function ownerOf(bytes32 hotkey) public view returns (bytes32) {
        bytes32 owner = _hotkeyOwner[hotkey];
        return owner == bytes32(0) ? keccak256(abi.encodePacked("owner:", hotkey)) : owner;
    }

    /// @dev The neuron mock's association: an ownerless hotkey goes to `coldkey`; an owned one stays put.
    function associate(bytes32 hotkey, bytes32 coldkey) external {
        if (_hasOwnerRecord(hotkey)) return;
        hotkeyDeleted[hotkey] = false;
        _assignOwner(hotkey, coldkey);
    }

    function getHotkeyOwner(bytes32 hotkey) external view returns (bool, bytes32) {
        bool exists = _hasOwnerRecord(hotkey);
        return (exists, exists ? ownerOf(hotkey) : bytes32(0));
    }

    mapping(bytes32 => bytes32[]) private _ownedHotkeys;
    /// @dev The index a hotkey currently sits in, so a change of owner can remove it from there.
    mapping(bytes32 => bytes32) private _indexedUnder;
    mapping(bytes32 => bytes32) private _coldkeyRoot;

    function getOwnedHotkeys(bytes32 coldkey) external view returns (bytes32[] memory) {
        return _ownedHotkeys[coldkey];
    }

    /// @dev The chain holds the owned hotkeys as a set.
    function _indexOwnedHotkey(bytes32 coldkey, bytes32 hotkey) private {
        _dropOwnedHotkey(hotkey);
        _ownedHotkeys[coldkey].push(hotkey);
        _indexedUnder[hotkey] = coldkey;
    }

    function _dropOwnedHotkey(bytes32 hotkey) private {
        bytes32 coldkey = _indexedUnder[hotkey];
        if (coldkey == bytes32(0)) return;
        bytes32[] storage owned = _ownedHotkeys[coldkey];
        for (uint256 i; i < owned.length; ++i) {
            if (owned[i] == hotkey) {
                owned[i] = owned[owned.length - 1];
                owned.pop();
                break;
            }
        }
        delete _indexedUnder[hotkey];
    }

    function getColdkeyRoot(bytes32 coldkey) external view returns (bool, bytes32) {
        return (_coldkeyRoot[coldkey] != bytes32(0), _coldkeyRoot[coldkey]);
    }

    function setColdkeyRoot(bytes32 coldkey, bytes32 root) external {
        _coldkeyRoot[coldkey] = root;
    }

    /// @dev The first coldkey of a swap lineage; a coldkey never swapped is its own root.
    function _rootOf(bytes32 coldkey) private view returns (bytes32) {
        bytes32 root = _coldkeyRoot[coldkey];
        return root == bytes32(0) ? coldkey : root;
    }

    /// @dev An incoming coldkey swap narrowed to one subnet. It models the rules a swap runs against the
    ///      destination: the destination is refused when it is itself a hotkey, and refused when it already
    ///      holds stake, which the chain tests across all subnets and this fixture tests on `netuid`. On a
    ///      swap the source's stake, owned hotkeys, locks and accept-locked flag all land on the destination.
    function simulateColdkeySwap(bytes32 source, bytes32 destination, uint256 netuid, bytes32[] calldata hotkeys)
        external
    {
        require(!_hasOwnerRecord(destination), "MockStaking: NewColdKeyIsHotkey");
        require(coldkeyAlpha[destination][netuid] == 0, "MockStaking: ColdKeyAlreadyAssociated");
        for (uint256 i; i < hotkeys.length; ++i) {
            uint256 amount = _stakes[hotkeys[i]][source][netuid];
            _writeStake(hotkeys[i], source, netuid, 0);
            _addStake(hotkeys[i], destination, netuid, amount);
        }
        lockedAlpha[destination][netuid] = lockedAlpha[source][netuid];
        lockHotkey[destination][netuid] = lockHotkey[source][netuid];
        delete lockedAlpha[source][netuid];
        delete lockHotkey[source][netuid];
        _acceptsLockedAlpha[destination] = _acceptsLockedAlpha[source];
        _coldkeyRoot[destination] = _rootOf(source);
        bytes32[] memory sourceHotkeys = _ownedHotkeys[source];
        for (uint256 i; i < sourceHotkeys.length; ++i) {
            _assignOwner(sourceHotkeys[i], destination);
        }
    }

    mapping(bytes32 => mapping(uint256 => bytes32)) private _successor;
    mapping(bytes32 => mapping(uint256 => bool)) private _successorSet;

    function setHotkeySuccessor(bytes32 from, uint256 netuid, bytes32 to) external {
        _successor[from][netuid] = to;
        _successorSet[from][netuid] = true;
    }

    function clearHotkeySuccessor(bytes32 hotkey, uint256 netuid) external {
        delete _successor[hotkey][netuid];
        delete _successorSet[hotkey][netuid];
    }

    function getHotkeySuccessor(bytes32 hotkey, uint16 netuid) external view returns (bool, bytes32) {
        return (_successorSet[hotkey][netuid], _successor[hotkey][netuid]);
    }

    /// @dev Zero denominator: sales quote at the alpha price; otherwise a fixed rate models price impact.
    uint256 public taoPerAlpha;
    uint256 public taoPerAlphaDenom;
    bool public removeStakeReverts;
    mapping(bytes32 => bool) public removeStakeRevertsFor;
    uint256 public nominatorMinRequiredStake;
    /// @dev Zero means uncapped.
    uint256 public removeStakeCap;

    function setNominatorMinRequiredStake(uint256 thresholdTao) external {
        nominatorMinRequiredStake = thresholdTao;
    }

    function getNominatorMinRequiredStake() external view returns (uint256) {
        return nominatorMinRequiredStake;
    }

    function setRemoveStakeRate(uint256 num, uint256 denom) external {
        taoPerAlpha = num;
        taoPerAlphaDenom = denom;
    }

    /// @dev TAO RAO a sale of `alpha` RAO pays on `netuid`.
    function quoteTaoOut(uint16 netuid, uint256 alpha) public view returns (uint256) {
        if (taoPerAlphaDenom != 0) return (alpha * taoPerAlpha) / taoPerAlphaDenom;
        return (alpha * MockAlpha(ALPHA_PRECOMPILE).chainAlphaPrice(netuid)) / VaultMath.ALPHA_PRICE_SCALE;
    }

    function setRemoveStakeReverts(bool v) external {
        removeStakeReverts = v;
    }

    function setRemoveStakeRevertsFor(bytes32 hotkey, bool v) external {
        removeStakeRevertsFor[hotkey] = v;
    }

    function setRemoveStakeCap(uint256 maxAlpha) external {
        removeStakeCap = maxAlpha;
    }

    function removeStake(bytes32 hotkey, uint256 alphaAmount, uint256 netuid) external payable {
        if (removeStakeReverts || removeStakeRevertsFor[hotkey]) _fail();
        bytes32 coldkey = _senderColdkey();
        _requireStakingOpen(netuid);
        uint256 staked = _stakes[hotkey][coldkey][netuid];
        alphaAmount = _u64(alphaAmount) < staked ? _u64(alphaAmount) : staked;
        if (alphaAmount == 0 || !_hasOwnerRecord(hotkey)) _fail();
        uint256 locked = lockedAlpha[coldkey][netuid];
        uint256 total = coldkeyAlpha[coldkey][netuid];
        if (alphaAmount > (total > locked ? total - locked : 0)) _fail();
        if (alphaAmount != staked && _simulatedSale(uint16(netuid), alphaAmount) < _chainMinStakeTao) _fail();
        uint256 consumed = removeStakeCap != 0 && alphaAmount > removeStakeCap ? removeStakeCap : alphaAmount;
        uint256 taoOut = quoteTaoOut(uint16(netuid), consumed);
        uint256 remainder = staked - consumed;
        if (_isSmallNomination(hotkey, coldkey, netuid, remainder)) {
            taoOut += quoteTaoOut(uint16(netuid), remainder);
            _reduceLock(coldkey, netuid, remainder);
            remainder = 0;
        }
        _writeStake(hotkey, coldkey, netuid, remainder);
        (bool ok,) = msg.sender.call{ value: taoOut * VaultMath.TAO_NATIVE_QUANTUM }("");
        require(ok, "MockStaking: TAO credit failed");
    }

    /// @dev A refused simulation refuses the sale.
    function _simulatedSale(uint16 netuid, uint256 alphaAmount) private view returns (uint256) {
        try MockAlpha(ALPHA_PRECOMPILE).simSwapAlphaForTao(netuid, uint64(alphaAmount)) returns (uint256 taoOut) {
            return taoOut;
        } catch {
            _fail();
        }
    }

    /// @dev The chain force-sells a non-owner's remainder below the nominator minimum, in alpha at the price.
    function _isSmallNomination(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 remainder)
        private
        view
        returns (bool)
    {
        if (remainder == 0 || nominatorMinRequiredStake == 0 || ownerOf(hotkey) == coldkey) return false;
        uint256 minAlpha = (nominatorMinRequiredStake * VaultMath.ALPHA_PRICE_SCALE)
            / MockAlpha(ALPHA_PRECOMPILE).chainAlphaPrice(uint16(netuid));
        return remainder < minAlpha;
    }
}
