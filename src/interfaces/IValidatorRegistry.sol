// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

uint256 constant MAX_VALIDATORS = 10;

interface IValidatorRegistry {
    /// @dev Hotkeys must be nonzero and distinct. The vault reads 0x0 as "no swap successor".
    ///      Every hotkey the vault stakes under must have an owner. The registry checks who the owner is.
    function getValidators(uint256 netuid) external view
        returns (bytes32[] memory hotkeys, uint16[] memory weights);

    /// @notice Validator updates landed for `netuid`; each landing increments it by one.
    function nonces(uint256 netuid) external view returns (uint256);
}
