// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { VaultMath } from "src/libraries/VaultMath.sol";

contract VaultMathTest is Test {
    function test_NovelSources_KeepsUnrecordedKeysOnceInOrder() public pure {
        bytes32[] memory recorded = new bytes32[](1);
        recorded[0] = bytes32(uint256(1));
        bytes32[] memory sources = new bytes32[](5);
        sources[0] = bytes32(uint256(1));
        sources[1] = bytes32(0);
        sources[2] = bytes32(uint256(3));
        sources[3] = bytes32(uint256(2));
        sources[4] = bytes32(uint256(3));

        bytes32[] memory strays = VaultMath.novelSources(recorded, sources);

        assertEq(strays.length, 2, "recorded, empty and repeated sources drop out");
        assertEq(strays[0], bytes32(uint256(3)), "the first unrecorded source stays first");
        assertEq(strays[1], bytes32(uint256(2)), "the later unrecorded source follows it");
    }
}
