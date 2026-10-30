// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CloneBase } from "../CloneBase.sol";
import { CloneFactory } from "../CloneFactory.sol";
import { IStaking, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { IAlphaVaultAbi } from "../interfaces/IAlphaVaultAbi.sol";
import { VaultReads } from "./VaultReads.sol";

/// @dev Runs inside a delegatecall from the vault, so the vault is the initializer and `msg.sender` is the
///      depositor.
library VaultClones {
    function deployMissingClone(CloneFactory factory, mapping(uint256 => address) storage subnetClone, uint256 tokenId,
        uint16 netuid, bytes32 uid) internal returns (address clone) {
        clone = subnetClone[tokenId];
        if (clone != address(0)) return clone;
        clone = deployProtectedClone(factory, tokenId, netuid, uid);
        subnetClone[tokenId] = clone;
        emit IAlphaVaultAbi.SubnetProxyCreated(tokenId, clone);
    }

    function deployMissingMailbox(CloneFactory factory, mapping(address => mapping(uint256 => address)) storage mailboxes,
        uint16 netuid, bytes32 uid) internal returns (address mailbox) {
        mailbox = mailboxes[msg.sender][netuid];
        if (mailbox != address(0)) return mailbox;
        mailbox = factory.deployMailbox(msg.sender, netuid, uid);
        bytes32 mailboxColdkey = VaultReads.coldkeyOf(mailbox);
        _initializeClone(mailbox, mailboxColdkey, mailboxColdkey);
        mailboxes[msg.sender][netuid] = mailbox;
        emit IAlphaVaultAbi.MailboxCreated(msg.sender, netuid, mailbox);
    }

    function deployProtectedClone(CloneFactory factory, uint256 tokenId, uint16 netuid, bytes32 uid)
        internal returns (address clone) {
        clone = factory.deploySubnetClone(tokenId, netuid, uid);
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        address owner = factory.deployCloneOwner(coldkey, netuid);
        _initializeClone(clone, coldkey, VaultReads.coldkeyOf(owner));
    }

    function _initializeClone(address clone, bytes32 coldkey, bytes32 owner) private {
        CloneBase(clone).initialize();
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        if (
            !VaultReads.ownedBy(coldkey, owner) || !staking.getRejectLockedAlpha(coldkey)
        ) revert IAlphaVaultAbi.CloneProtectionFailed(clone);
    }
}
