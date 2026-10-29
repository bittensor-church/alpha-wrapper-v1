// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IValidatorRegistry } from "./IValidatorRegistry.sol";
import { IAlphaVaultAbi } from "./IAlphaVaultAbi.sol";

/// @notice Subset of AlphaVault for contracts that hold its shares.
interface IAlphaVault is IERC1155, IAlphaVaultAbi {
    function currentTokenId(uint256 netuid) external view returns (uint256);
    function parkingHotkey() external view returns (bytes32);
    function validatorRegistry() external view returns (IValidatorRegistry);
    function unwrap(uint256 tokenId, uint256 shares, bytes32 userSubstrateColdkey, uint256 minAlphaOut) external;
    function claimTao(uint256 tokenId, address payable recipient) external;
}
