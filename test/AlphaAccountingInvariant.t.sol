// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { CampaignHarness } from "./helpers/CampaignHarness.sol";
import { AlphaVault } from "src/AlphaVault.sol";
import { CHAIN_MIN_STAKE } from "./mocks/MockStaking.sol";

/// @dev Healthy chain campaign: one owned validator, no losses and no sweep threshold, with a moving price and
///      emissions. These preconditions make adequately sized exits mandatory, so failures must never be caught.
contract AlphaAccountingHandler is Test {
    uint256 private constant VIRTUAL_SHARES = 1e9;

    AlphaVault public immutable vault;
    AlphaAccountingCampaignSetup public immutable harness;
    uint256 public immutable tokenId;
    address[3] public actors;
    uint256 public deposited;
    uint256 public emitted;
    uint256 public alphaDelivered;
    uint256 public alphaSold;
    uint256 public shareConversions;
    uint256 public partialExits;
    uint256 public virtualShareSlice;

    constructor(AlphaAccountingCampaignSetup owner, AlphaVault v, uint256 id, address[3] memory users) {
        harness = owner;
        vault = v;
        tokenId = id;
        actors = users;
    }

    function wrap(uint256 actorSeed, uint256 amount) external {
        _deposit(actors[actorSeed % actors.length], bound(amount, 10e9, 1_000e9));
    }

    function _deposit(address actor, uint256 amount) private {
        uint256 held = vault.balanceOf(actor, tokenId);
        uint256 owed = amount * (vault.totalSupply(tokenId) + VIRTUAL_SHARES) / (harness.chainBacking() + 1);
        harness.depositFor(actor, amount, owed);
        assertGt(owed, 0, "a healthy deposit is worth a share");
        assertEq(vault.balanceOf(actor, tokenId) - held, owed, "a deposit buys its share at the current rate");
        deposited += amount;
        ++shareConversions;
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = vault.balanceOf(from, tokenId);
        if (balance == 0) return;
        uint256 sent = bound(amount, 0, balance);
        vm.prank(from);
        vault.safeTransferFrom(from, to, tokenId, sent, "");
    }

    function unwrap(uint256 actorSeed, uint256 shareSeed, bool forTao) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = vault.balanceOf(actor, tokenId);
        if (balance == 0) return;
        uint256 shares = bound(shareSeed, 1, balance);
        if (shares == balance || _belowStakeMinimum(_owed(shares))) {
            _exitInFull(actor, forTao);
            return;
        }
        ++partialExits;
        _redeem(actor, shares, forTao);
    }

    function _exitInFull(address actor, bool forTao) private {
        uint256 shares = vault.balanceOf(actor, tokenId);
        if (shares == 0) return;
        // A share transfer can leave a sub-floor holder. A real top-up makes that position exit-able.
        if (_belowStakeMinimum(_owed(shares))) {
            _deposit(actor, 10e9);
            shares = vault.balanceOf(actor, tokenId);
        }
        _redeem(actor, shares, forTao);
        assertEq(vault.balanceOf(actor, tokenId), 0, "a healthy full exit retires the holder's shares");
    }

    function _owed(uint256 shares) private view returns (uint256) {
        return shares * (harness.chainBacking() + 1) / (vault.totalSupply(tokenId) + VIRTUAL_SHARES);
    }

    function _belowStakeMinimum(uint256 alpha) private view returns (bool) {
        return alpha * harness.price() / 1e18 < CHAIN_MIN_STAKE;
    }

    function _redeem(address actor, uint256 shares, bool forTao) private {
        uint256 held = vault.balanceOf(actor, tokenId);
        uint256 backing = harness.chainBacking();
        uint256 supply = vault.totalSupply(tokenId);
        uint256 owed = shares * (backing + 1) / (supply + VIRTUAL_SHARES);
        virtualShareSlice = 0;
        if (forTao) {
            uint256 sold = shares == supply ? backing : owed;
            uint256 pays = sold * harness.price() / 1e18 * 1e9;
            uint256 taoBefore = actor.balance;
            vm.prank(actor);
            vault.unwrapForTao(tokenId, shares, pays);
            assertEq(backing - harness.chainBacking(), sold, "a TAO exit sells the holder's share");
            assertEq(actor.balance - taoBefore, pays, "TAO sale pays alpha x price in native units");
            alphaSold += sold;
        } else {
            bytes32 recipient = keccak256(abi.encodePacked("evm:", actor));
            uint256 stakeBefore = harness.recipientStake(actor);
            vm.prank(actor);
            vault.unwrap(tokenId, shares, recipient, owed);
            assertEq(harness.recipientStake(actor) - stakeBefore, owed, "an alpha exit delivers the holder's share");
            assertEq(backing - harness.chainBacking(), owed, "alpha reaches the caller's destination");
            alphaDelivered += owed;
            if (shares == supply) virtualShareSlice = backing * VIRTUAL_SHARES / (supply + VIRTUAL_SHARES) + 1;
        }
        assertEq(vault.balanceOf(actor, tokenId), held - shares, "an exit burns exactly the shares asked");
        ++shareConversions;
    }

    function movePrice(uint256 priceSeed) external {
        harness.movePrice(priceSeed);
    }

    function accrueEmissions(uint256 amount) external {
        if (harness.chainBacking() == 0) return;
        uint256 emission = bound(amount, 1e9, 300e9);
        harness.accrueEmissions(emission);
        emitted += emission;
        if (vault.totalSupply(tokenId) == 0) virtualShareSlice += emission;
    }

    function closeAllPositions() external {
        for (uint256 i; i < actors.length; ++i) {
            _exitInFull(actors[i], i % 2 == 0);
        }
    }
}

abstract contract AlphaAccountingCampaignSetup is CampaignHarness {
    AlphaAccountingHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        _setValidators(NETUID1, _hotkeys(hotkey1), _weights(BPS_BASE));
        _setDustThreshold(0);
        handler = new AlphaAccountingHandler(this, vault, TOKEN1, [alice, bob, makeAddr("carol")]);
        handler.wrap(0, 50e9);
        handler.wrap(1, 50e9);
    }

    function depositFor(address actor, uint256 amount, uint256 minSharesOut) external {
        _simulateAlphaDeposit(actor, NETUID1, amount);
        bytes32 chosenHotkey = hotkey1;
        vm.prank(actor);
        vault.wrap(NETUID1, chosenHotkey, minSharesOut);
    }

    function price() external view returns (uint256) {
        return _alphaPriceRead(NETUID1);
    }

    function accrueEmissions(uint256 amount) external {
        _simulateEmissions(NETUID1, amount);
    }

    function chainBacking() public view returns (uint256) {
        return _getVaultStake(hotkey1, NETUID1);
    }

    function recipientStake(address actor) public view returns (uint256) {
        return _getStake(hotkey1, actor, NETUID1);
    }

    function _assertAlphaConserved() internal view {
        assertEq(
            chainBacking() + handler.alphaDelivered() + handler.alphaSold(),
            handler.deposited() + handler.emitted(),
            "deposited and emitted alpha is neither held, delivered nor sold"
        );
    }

    function _assertEveryHolderLeaves() internal {
        handler.closeAllPositions();
        assertEq(vault.totalSupply(TOKEN1), 0, "every healthy holder can leave");
        assertLe(
            chainBacking(),
            handler.shareConversions() + handler.virtualShareSlice(),
            "at most one RAO per share conversion stays behind, beside the virtual shares' slice"
        );
        _assertAlphaConserved();
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract AlphaAccountingInvariantTest is AlphaAccountingCampaignSetup {
    function setUp() public override {
        super.setUp();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.wrap.selector;
        selectors[1] = handler.transferShares.selector;
        selectors[2] = handler.unwrap.selector;
        selectors[3] = handler.movePrice.selector;
        selectors[4] = handler.accrueEmissions.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariant_EveryDepositedOrEmittedAlphaIsHeldDeliveredOrSold() public view {
        _assertAlphaConserved();
    }

    function afterInvariant() public {
        _assertEveryHolderLeaves();
    }
}

contract AlphaAccountingCampaignPathsTest is AlphaAccountingCampaignSetup {
    function test_FixedCampaign_PricesEveryDepositAndExitAtTheHoldersShare() public {
        address carol = handler.actors(2);

        handler.wrap(2, 25e9);
        assertEq(vault.balanceOf(carol, TOKEN1), 2.5e19, "25 alpha into 100 alpha and 1e20 shares buys 2.5e19 shares");

        handler.accrueEmissions(25e9);
        assertEq(chainBacking(), 150e9, "emissions raise the backing to 150 alpha");
        handler.movePrice(1e8);
        assertEq(this.price(), 0.1e18, "the price moves to 0.1 TAO per alpha");

        handler.unwrap(0, 1e19, false);
        assertEq(recipientStake(alice), 11_999_999_999, "1e19 of 1.25e20 shares redeem 12 alpha less one RAO");
        assertEq(vault.balanceOf(alice, TOKEN1), 4e19, "the partial alpha exit burns 1e19 shares");

        handler.unwrap(1, 2e19, true);
        assertEq(bob.balance, 2.4 ether, "24 alpha sell for 2.4 TAO at 0.1 TAO per alpha");
        assertEq(vault.balanceOf(bob, TOKEN1), 3e19, "the partial TAO exit burns 2e19 shares");

        handler.transferShares(2, 0, 5e18);
        assertEq(vault.balanceOf(alice, TOKEN1), 4.5e19, "the transfer lands on the receiver");
        assertEq(vault.balanceOf(carol, TOKEN1), 2e19, "the transfer leaves the sender");

        _assertEveryHolderLeaves();
        assertEq(alice.balance, 5.4 ether, "4.5e19 of 9.5e19 shares sell 54 alpha for 5.4 TAO");
        assertEq(recipientStake(bob), 36e9, "3e19 of 5e19 shares redeem 36 alpha");
        assertEq(carol.balance, 2.4 ether, "the last holder sells the remaining 24.000000001 alpha for 2.4 TAO");
        assertEq(chainBacking(), 0, "the last TAO exit sells the whole backing");
    }
}
