// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IValidatorRegistry } from "src/interfaces/IValidatorRegistry.sol";
import { VaultReads } from "src/libraries/VaultReads.sol";

/// @dev Exposes the resolver so tests can see the set the vault reads. No external call returns it
///      any more, and a corrupt set's shape is otherwise invisible from outside.
contract VaultReadsHarness {
    function resolveValidators(IValidatorRegistry registry, uint16 netuid)
        external
        view
        returns (VaultReads.ValidatorSet memory)
    {
        return VaultReads.resolveValidators(registry, netuid);
    }
}
