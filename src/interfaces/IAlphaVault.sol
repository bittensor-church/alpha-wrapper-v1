// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { CloneFactory } from "../CloneFactory.sol";
import { VaultReads } from "../libraries/VaultReads.sol";
import { IValidatorRegistry } from "./IValidatorRegistry.sol";
import { IAlphaVaultAbi } from "./IAlphaVaultAbi.sol";

interface IAlphaVault is IERC1155, IAlphaVaultAbi {
    function cloneFactory() external view returns (CloneFactory);
    function validatorRegistry() external view returns (IValidatorRegistry);
    function recoveryWindow() external view returns (uint256);
    function parkingHotkey() external view returns (bytes32);
    function subnetClone(uint256 tokenId) external view returns (address);
    function recovery(uint256 tokenId) external view returns (uint256 shortSince, uint256 parkedAtNonce);
    function cumulativeTaoPerShare(uint256 tokenId) external view returns (uint256);
    function taoLiability(uint256 tokenId) external view returns (uint256);
    function taoIndexDebt(uint256 tokenId, address account) external view returns (uint256);
    function claimableTao(uint256 tokenId, address account) external view returns (uint256);
    function totalSupply(uint256 tokenId) external view returns (uint256);

    function currentTokenId(uint256 netuid) external view returns (uint256);
    function createMailbox(uint256 netuid, bytes32 uid) external returns (address mailbox, address clone);
    function getDepositAddress(address user, uint256 netuid) external view returns (address);
    function awaitingAttestation(uint256 tokenId) external view returns (bool);
    function wrap(uint256 netuid, bytes32 chosenHotkey, uint256 minSharesOut) external;
    function unwrap(uint256 tokenId, uint256 shares, bytes32 userSubstrateColdkey, uint256 minAlphaOut) external;
    function unwrapForTao(uint256 tokenId, uint256 shares, uint256 minTaoOut) external;
    function unwrapForTao(uint256 tokenId, uint256 shares, uint256 minTaoOut, uint256 excludedSlots) external;
    function claimTao(uint256 tokenId, address payable recipient) external;
    function rebalance(uint256 netuid) external;
    function reclaimTaoFromMailbox(uint256 netuid) external;
    function reclaimAlphaFromMailbox(uint256 netuid, bytes32 hotkey, bytes32 destSubstrateColdkey) external;
    function reclaimMailboxAlphaAsTao(uint256 netuid, bytes32 hotkey, uint256 minTaoOut) external;
    function recoverStray(uint256 tokenId, bytes32 source) external;
    function syncBacking(uint256 tokenId) external;
    function recordedSlots(uint256 tokenId) external view returns (VaultReads.Slot[] memory);
}
