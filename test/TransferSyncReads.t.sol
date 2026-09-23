// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVaultTestBase } from "./AlphaVaultTestBase.sol";
import { ISubnet, SUBNET_PRECOMPILE } from "src/interfaces/ISubnet.sol";

contract TransferSyncReadsTest is AlphaVaultTestBase {
    uint256 internal constant DEPOSIT = 30 ether;
    uint256 internal constant DONATION = 3 ether;
    uint256 internal constant NATIVE_TRANSFER_QUANTUM = 1e9;

    function setUp() public override {
        super.setUp();
        _depositAndWrap(alice, NETUID1, DEPOSIT);
        _depositAndWrap(alice, NETUID2, DEPOSIT);
    }

    function _expectSubnetReads(uint256 netuid, uint64 count) private {
        uint16 id = uint16(netuid);
        vm.expectCall(SUBNET_PRECOMPILE, abi.encodeCall(ISubnet.getRegisteredSubnetCounter, (id)), count);
        vm.expectCall(SUBNET_PRECOMPILE, abi.encodeCall(ISubnet.getNetworkRegistrationBlock, (id)), count);
        vm.expectCall(SUBNET_PRECOMPILE, abi.encodeCall(ISubnet.isSubnetDissolving, (id)), count);
    }

    function _transferHalf(uint256 tokenId) private {
        uint256 shares = vault.balanceOf(alice, tokenId) / 2;
        vm.prank(alice);
        vault.safeTransferFrom(alice, bob, tokenId, shares, "");
    }

    function _batchTransferHalf() private {
        uint256[] memory ids = new uint256[](2);
        ids[0] = TOKEN1;
        ids[1] = TOKEN2;
        uint256[] memory values = new uint256[](2);
        values[0] = vault.balanceOf(alice, TOKEN1) / 2;
        values[1] = vault.balanceOf(alice, TOKEN2) / 2;
        vm.prank(alice);
        vault.safeBatchTransferFrom(alice, bob, ids, values, "");
    }

    function test_TransferWithoutUnreservedTao_ReadsNothingFromTheSubnetPrecompile() public {
        _expectSubnetReads(NETUID1, 0);
        _expectSubnetReads(NETUID2, 0);

        _transferHalf(TOKEN1);
        _batchTransferHalf();

        assertEq(vault.taoLiability(TOKEN1), 0);
        assertEq(vault.taoLiability(TOKEN2), 0);
    }

    function test_TransferAfterDonation_ReadsSubnetStateOnceAndReservesTheDonation() public {
        _donateToClone(vault.subnetClone(TOKEN1), DONATION);
        _expectSubnetReads(NETUID1, 1);

        _transferHalf(TOKEN1);

        assertApproxEqAbs(vault.taoLiability(TOKEN1), DONATION, NATIVE_TRANSFER_QUANTUM, "the donation is reserved");
        assertApproxEqAbs(lens.claimableTaoOf(alice, TOKEN1), DONATION, NATIVE_TRANSFER_QUANTUM);
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 0);
    }

    function test_BatchTransferAfterDonations_ReadsSubnetStateOncePerToken() public {
        _donateToClone(vault.subnetClone(TOKEN1), DONATION);
        _donateToClone(vault.subnetClone(TOKEN2), DONATION);
        _expectSubnetReads(NETUID1, 1);
        _expectSubnetReads(NETUID2, 1);

        _batchTransferHalf();

        assertApproxEqAbs(vault.taoLiability(TOKEN1), DONATION, NATIVE_TRANSFER_QUANTUM);
        assertApproxEqAbs(vault.taoLiability(TOKEN2), DONATION, NATIVE_TRANSFER_QUANTUM);
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 0);
        assertEq(lens.claimableTaoOf(bob, TOKEN2), 0);
    }

    function test_SecondTransferAfterDonation_ReadsNothing() public {
        _donateToClone(vault.subnetClone(TOKEN1), DONATION);
        _transferHalf(TOKEN1);

        _expectSubnetReads(NETUID1, 0);
        _transferHalf(TOKEN1);
        _batchTransferHalf();
    }
}
