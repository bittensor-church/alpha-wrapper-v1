// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

contract MockRuntimeConfiguration {
    uint256 public minTransferWei;

    function setMinTransferWei(uint256 amount) external {
        minTransferWei = amount;
    }

    function getSubtensorEconomicConstants()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (0, 0, 0, 0, 0, 0, minTransferWei, 0, 0, 0, 0, 0, 0);
    }
}
