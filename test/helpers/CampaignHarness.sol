// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "../AlphaVaultTestBase.sol";

/// @dev A campaign call may fail only with an error its entry point is documented to raise; a panic, a refused chain
///      call (empty revert data) or any other error fails the campaign.
function requireExpectedRevert(bytes memory reason, bytes4[] memory expected) pure {
    bytes4 selector = bytes4(reason);
    for (uint256 i; i < expected.length; ++i) {
        if (selector == expected[i]) return;
    }
    assembly {
        revert(add(reason, 32), mload(reason))
    }
}

abstract contract CampaignHarness is AlphaVaultTestBase {
    function movePrice(uint256 priceSeed) external {
        _setAlphaPrice(NETUID1, _wholeRaoPrice(priceSeed));
    }
}
