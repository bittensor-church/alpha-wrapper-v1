// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { CloneOwner } from "./CloneOwner.sol";
import { IStaking, STAKING_PRECOMPILE } from "./interfaces/IStaking.sol";
import { VaultReads } from "./libraries/VaultReads.sol";
import { IAlphaVaultAbi } from "./interfaces/IAlphaVaultAbi.sol";

/// @dev Deployed and owned by the vault, which makes each clone a hotkey (a mailbox its own, a subnet
///      clone its owner contract's) and verifies that protection before publishing its address.
contract CloneFactory {
    address public immutable vault;
    address public immutable mailboxLogic; address public immutable subnetLogic;

    error NotVault();

    constructor(address _mailboxLogic, address _subnetLogic) {
        vault = msg.sender; mailboxLogic = _mailboxLogic; subnetLogic = _subnetLogic;
    }

    modifier onlyVault() { if (msg.sender != vault) revert NotVault(); _; }

    /// @dev The caller's UID picks the candidate address, so a poisoned one is retried with a fresh UID.
    function deployMailbox(address user, uint16 netuid, bytes32 uid) external onlyVault returns (address) {
        return _deploy(mailboxLogic, keccak256(abi.encode("mailbox-v1", user, netuid, uid)), netuid);
    }

    function deploySubnetClone(uint256 tokenId, uint16 netuid, bytes32 uid) external onlyVault returns (address) {
        return _deploy(subnetLogic, keccak256(abi.encode("subnet-v1", tokenId, uid)), netuid);
    }

    /// @dev The owner claims `hotkey` in its constructor, so it holds the claim before anyone can act on it.
    function deployCloneOwner(bytes32 hotkey, uint16 netuid, bytes32 uid) external onlyVault returns (address owner) {
        bytes32 salt = keccak256(abi.encode("owner-v1", hotkey, uid));
        bytes memory initCode = abi.encodePacked(type(CloneOwner).creationCode, abi.encode(hotkey));
        owner = Create2.computeAddress(salt, keccak256(initCode));
        _requireClean(owner, netuid);
        Create2.deploy(0, salt, initCode);
    }

    function _deploy(address implementation, bytes32 salt, uint16 netuid) private returns (address candidate) {
        candidate = Clones.predictDeterministicAddress(implementation, salt, address(this));
        _requireClean(candidate, netuid);
        Clones.cloneDeterministic(implementation, salt);
    }

    /// @dev A swap can import ownership roles that create future locks even if today's lock is zero, and
    ///      stake gifted before the clone refuses list growth already occupies the list that admits deposits.
    ///      TAO gifts give their sender no authority over this account.
    function _requireClean(address candidate, uint16 netuid) private view {
        bytes32 coldkey = VaultReads.coldkeyOf(candidate);
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        (bool owned,) = staking.getHotkeyOwner(coldkey);
        (bool swapped,) = staking.getColdkeyRoot(coldkey);
        if (
            owned || swapped || staking.getOwnedHotkeys(coldkey).length != 0
                || VaultReads.lockedAlphaOf(coldkey, netuid) != 0 || VaultReads.stakingHotkeyCount(coldkey) != 0
        ) revert IAlphaVaultAbi.CloneContaminated(candidate);
    }
}
