// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CloneBase } from "../CloneBase.sol";
import { CloneFactory } from "../CloneFactory.sol";
import { INeuron, NEURON_PRECOMPILE } from "../interfaces/INeuron.sol";
import { IStaking, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { IAlphaVaultAbi } from "../interfaces/IAlphaVaultAbi.sol";
import { VaultReads } from "./VaultReads.sol";

/// @dev Creation of the per-registration subnet clone and of the caller's own deposit mailbox. Runs
///      inside a delegatecall from the vault, so the vault is the initializer and `msg.sender` is the
///      depositor. Compiled into each caller.
library VaultClones {
    /// @dev Publish an address only once its protection is verified.
    function prepareClones(CloneFactory factory, mapping(uint256 => address) storage subnetClone,
        mapping(address => mapping(uint256 => address)) storage mailboxes, uint256 tokenId, uint256 netuid,
        bytes32 uid) internal returns (address mailbox, address clone) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 nid = uint16(netuid);
        VaultReads.requireNotDissolving(nid);
        clone = subnetClone[tokenId];
        if (clone == address(0)) {
            clone = factory.deploySubnetClone(tokenId, nid, uid);
            _initializeClone(clone, false);
            subnetClone[tokenId] = clone;
            emit IAlphaVaultAbi.SubnetProxyCreated(tokenId, clone);
        }
        mailbox = mailboxes[msg.sender][netuid];
        if (mailbox == address(0)) {
            mailbox = factory.deployMailbox(msg.sender, nid, uid);
            _initializeClone(mailbox, true);
            mailboxes[msg.sender][netuid] = mailbox;
            emit IAlphaVaultAbi.MailboxCreated(msg.sender, netuid, mailbox);
        }
    }

    /// @dev A subnet clone must own no hotkey: the chain hands a subnet to whoever owns its most convicted
    ///      hotkey and then locks the owner's cut onto that coldkey, which would freeze the clone. The vault
    ///      owns the clone's account instead, which still refuses coldkey swaps into it.
    function _initializeClone(address clone, bool ownsItself) private {
        CloneBase(payable(clone)).initialize(address(this));
        bytes32 coldkey = VaultReads.coldkeyOf(clone);
        bytes32 owner = coldkey;
        if (!ownsItself) {
            owner = VaultReads.coldkeyOf(address(this));
            INeuron(NEURON_PRECOMPILE).tryAssociateHotkey(coldkey);
        }
        IStaking staking = IStaking(STAKING_PRECOMPILE);
        if (
            !VaultReads.ownedBy(coldkey, owner) || !staking.getRejectLockedAlpha(coldkey)
                || !staking.getRejectStakingHotkeyGrowth(coldkey)
        ) revert IAlphaVaultAbi.CloneProtectionFailed(clone);
    }
}
