// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @dev Fixtures seed the deposit after `vm.etch`, which copies code but not storage.
contract MockRuntimeConfiguration {
    uint256 public existentialDeposit;

    function setExistentialDeposit(uint256 deposit) external {
        existentialDeposit = deposit;
    }

    function getBalancesConstants() external view returns (uint256, uint32, uint32, uint32) {
        return (existentialDeposit, 50, 50, 50);
    }
}
