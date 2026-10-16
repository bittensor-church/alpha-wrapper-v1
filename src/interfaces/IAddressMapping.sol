// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

address constant ADDRESS_MAPPING_PRECOMPILE = 0x000000000000000000000000000000000000080C;

/// @dev Excerpt of the Address Mapping precompile interface published in Subtensor; docs/deployment.md
///      lists the behavior the vault relies on.
interface IAddressMapping {
    function addressMapping(address evmAddress) external view returns (bytes32);
}
