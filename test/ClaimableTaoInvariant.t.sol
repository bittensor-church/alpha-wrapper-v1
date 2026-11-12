// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { CampaignHarness, requireExpectedRevert } from "./helpers/CampaignHarness.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { ClaimBelowNativePrecision, WithdrawTooSmall, ZeroAmount } from "src/VaultErrors.sol";

contract ClaimableTaoHandler is Test {
    AlphaVault public immutable vault;
    ClaimableTaoCampaignSetup public immutable harness;
    uint256 public immutable tokenId;
    address[] public actors;
    uint256 public totalDonated;
    uint256 public totalClaimed;
    uint256 public allocations;
    uint256 public balanceChanges;
    uint256 public taoExits;
    uint256 public refusedClaims;
    uint256 public unassigned;
    mapping(address => uint256) public earned;
    mapping(address => uint256) public claimed;

    constructor(AlphaVault _vault, ClaimableTaoCampaignSetup _harness, uint256 _tokenId, address[] memory _actors) {
        vault = _vault;
        harness = _harness;
        tokenId = _tokenId;
        actors = _actors;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @dev Chain balances move in whole RAO.
    function donate(uint256 amountRao) external {
        uint256 amount = bound(amountRao, 1e7, 1e11) * 1e9;
        address clone = vault.subnetClone(tokenId);
        vm.deal(clone, clone.balance + amount);
        totalDonated += amount;
        _allocate(amount);
    }

    // Independent arrival ledger: split each gift using the balances at arrival.
    function _allocate(uint256 amount) private {
        uint256 supply = vault.totalSupply(tokenId);
        if (supply == 0) {
            unassigned += amount;
            return;
        }
        ++allocations;
        for (uint256 i; i < actors.length; ++i) {
            earned[actors[i]] += amount * vault.balanceOf(actors[i], tokenId) / supply;
        }
    }

    function wrap(uint256 actorSeed, uint256 amount) external {
        harness.wrapFor(_actor(actorSeed), bound(amount, 10, 1_000) * 1e9);
        ++balanceChanges;
        if (unassigned != 0) {
            uint256 arrival = unassigned;
            unassigned = 0;
            _allocate(arrival);
        }
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = vault.balanceOf(from, tokenId);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(from);
        vault.safeTransferFrom(from, to, tokenId, amount, "");
        balanceChanges += 2;
    }

    function claim(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        if (harness.quotedClaim(actor) == 0) {
            _claimNothingQuoted(actor);
            return;
        }
        address clone = vault.subnetClone(tokenId);
        uint256 cloneBefore = clone.balance;
        uint256 delivered = harness.claimQuotedFor(actor);
        assertEq(cloneBefore - clone.balance, delivered, "a claim pays from the clone");
        assertEq(harness.quotedClaim(actor), 0, "a claim leaves less than one RAO quoted");
        totalClaimed += delivered;
        claimed[actor] += delivered;
    }

    function _claimNothingQuoted(address actor) private {
        uint256 before = actor.balance;
        vm.prank(actor);
        try vault.claimTao(tokenId, payable(actor)) {
            assertEq(actor.balance, before, "a claim paid TAO the lens did not quote");
        } catch (bytes memory reason) {
            bytes4[] memory expected = new bytes4[](2);
            expected[0] = ZeroAmount.selector;
            expected[1] = ClaimBelowNativePrecision.selector;
            requireExpectedRevert(reason, expected);
            ++refusedClaims;
        }
    }

    function exitForTao(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        uint256 shares = bound(shareSeed, 1, balance);
        address clone = vault.subnetClone(tokenId);
        uint256 cloneTao = clone.balance;
        uint256 holderTao = actor.balance;
        vm.prank(actor);
        try vault.unwrapForTao(tokenId, shares, 0) {
            ++taoExits;
            balanceChanges += 2;
            assertGt(actor.balance, holderTao, "a TAO exit pays the holder");
            assertEq(clone.balance, cloneTao, "a TAO exit leaves the clone's TAO for its claimants");
        } catch (bytes memory reason) {
            bytes4[] memory expected = new bytes4[](2);
            expected[0] = ZeroAmount.selector;
            expected[1] = WithdrawTooSmall.selector;
            requireExpectedRevert(reason, expected);
            uint256 assets = harness.taoExitAssets(shares);
            if (bytes4(reason) == ZeroAmount.selector) assertEq(assets, 0, "refused shares worth a RAO");
            else assertFalse(harness.taoExitSells(assets), "refused a TAO exit that sells");
        }
    }

    function movePrice(uint256 priceSeed) external {
        harness.movePrice(priceSeed);
    }
}

abstract contract ClaimableTaoCampaignSetup is CampaignHarness {
    ClaimableTaoHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = makeAddr("carol");
        for (uint256 i; i < actors.length; ++i) {
            _depositAndWrap(actors[i], NETUID1, 50 * ALPHA);
        }
        handler = new ClaimableTaoHandler(vault, this, TOKEN1, actors);
        targetContract(address(handler));
    }

    function wrapFor(address user, uint256 amount) external {
        _depositAndWrap(user, NETUID1, amount);
    }

    function quotedClaim(address user) external view returns (uint256) {
        return lens.claimableTaoOf(user, TOKEN1);
    }

    function claimQuotedFor(address user) external returns (uint256 delivered) {
        return _claimQuotedAmount(user, TOKEN1);
    }

    function taoExitAssets(uint256 shares) external view returns (uint256) {
        uint256 backing = _vaultStakeAcross(_recordedHotkeys(TOKEN1), NETUID1);
        uint256 supply = vault.totalSupply(TOKEN1);
        return shares == supply ? backing : shares * (backing + 1) / (supply + 1e9);
    }

    function taoExitSells(uint256 assets) external view returns (bool) {
        return _taoExitSellsWithin(_recordedHotkeys(TOKEN1), assets, 0, NETUID1);
    }

    function _assertCloneBalanceCoversReservedTao() internal view {
        assertGe(vault.subnetClone(TOKEN1).balance, vault.taoLiability(TOKEN1), "the clone holds less than it owes");
    }

    function _assertEachHolderKeepsTheirShare() internal view {
        uint256 changes = handler.balanceChanges();
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            uint256 received = handler.claimed(actor) + lens.claimableTaoOf(actor, TOKEN1);
            uint256 owed = handler.earned(actor);
            assertLe(received, owed + handler.allocations() + changes, "a holder received another holder's TAO");
            assertLe(owed, received + 1e9 + 2 + 2 * changes, "a holder lost TAO that arrived during their holding");
        }
    }

    function _assertEveryDonatedWeiIsPaidOrStillOnTheClone() internal view {
        assertEq(
            vault.subnetClone(TOKEN1).balance + handler.totalClaimed(),
            handler.totalDonated(),
            "donated TAO is neither paid nor on the clone"
        );
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract ClaimableTaoInvariantTest is ClaimableTaoCampaignSetup {
    function invariant_CloneBalanceCoversReservedTao() public view {
        _assertCloneBalanceCoversReservedTao();
    }

    function invariant_EachHolderKeepsTheirShareOfEveryArrival() public view {
        _assertEachHolderKeepsTheirShare();
    }

    function invariant_EveryDonatedWeiIsPaidOrStillOnTheClone() public view {
        _assertEveryDonatedWeiIsPaidOrStillOnTheClone();
    }
}

contract ClaimableTaoCampaignPathsTest is ClaimableTaoCampaignSetup {
    function test_FixedCampaign_PaysEachArrivalToItsHoldersAtArrival() public {
        address carol = handler.actors(2);

        handler.donate(3e9);
        assertEq(
            lens.claimableTaoOf(alice, TOKEN1), 1 ether, "a third of 3 TAO arrives for each of three equal holders"
        );
        handler.claim(0);
        assertEq(alice.balance, 1 ether, "alice claims her third");

        handler.transferShares(1, 0, 2.5e19);
        assertEq(vault.balanceOf(alice, TOKEN1), 7.5e19, "bob sends alice half his shares");
        handler.donate(3e9);
        assertEq(lens.claimableTaoOf(alice, TOKEN1), 1.5 ether, "alice holds half the supply for the second 3 TAO");
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 1.5 ether, "bob holds a third, then a sixth of the supply");
        assertEq(lens.claimableTaoOf(carol, TOKEN1), 2 ether, "carol holds a third of the supply for both arrivals");

        handler.claim(1);
        assertEq(bob.balance, 1.5 ether, "bob claims what arrived before and after his transfer");
        handler.claim(1);
        assertEq(bob.balance, 1.5 ether, "the refused claim pays nothing");

        handler.exitForTao(2, 5e19);
        assertEq(carol.balance, 2.49975 ether, "the 49.995-alpha slot drains at 0.05 TAO per alpha");
        assertEq(vault.balanceOf(carol, TOKEN1), 5e15, "the unsold 0.005 alpha refunds as 5e15 shares");
        handler.movePrice(1e8);

        assertEq(lens.claimableTaoOf(alice, TOKEN1), 1.5 ether, "alice still has the second arrival to claim");
        assertEq(lens.claimableTaoOf(bob, TOKEN1), 0, "bob claimed everything");
        assertEq(lens.claimableTaoOf(carol, TOKEN1), 2 ether, "carol keeps her claim after leaving");
        assertEq(vault.subnetClone(TOKEN1).balance, 3.5 ether, "the unclaimed 3.5 TAO stays on the clone");
        _assertCloneBalanceCoversReservedTao();
        _assertEachHolderKeepsTheirShare();
        _assertEveryDonatedWeiIsPaidOrStillOnTheClone();
    }
}
