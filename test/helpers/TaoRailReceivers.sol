// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AlphaVault } from "src/AlphaVault.sol";
import { AlphaVaultLens } from "src/AlphaVaultLens.sol";

contract RevertingReceiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    receive() external payable {
        revert("nope");
    }
}

contract RefundRejectingReceiver {
    bool private rejecting;

    function rejectMints() external {
        rejecting = true;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        require(!rejecting, "no mints");
        return this.onERC1155Received.selector;
    }

    receive() external payable { }
}

/// @dev Capture the re-entry error so tests can distinguish the guard from incidental failures.
contract UnwrapForTaoReentrantReceiver {
    AlphaVault target;
    uint256 tokenId;
    uint256 shares;
    bytes public reentryError;
    bool public reentrySucceeded;
    bool private entered;

    function arm(AlphaVault t, uint256 tid, uint256 s) external {
        target = t;
        tokenId = tid;
        shares = s;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        try target.unwrapForTao(tokenId, shares, 0) {
            reentrySucceeded = true;
        } catch (bytes memory err) {
            reentryError = err;
        }
    }
}

/// @dev Capture the re-entry error without reverting the outer payout.
contract ReclaimMailboxReentrantReceiver {
    AlphaVault target;
    uint256 netuid;
    bytes32 hotkey;
    bytes public reentryError;
    bool public reentrySucceeded;
    bool private entered;

    function arm(AlphaVault t, uint256 n, bytes32 h) external {
        target = t;
        netuid = n;
        hotkey = h;
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        try target.reclaimMailboxAlphaAsTao(netuid, hotkey, 0) {
            reentrySucceeded = true;
        } catch (bytes memory err) {
            reentryError = err;
        }
    }
}

contract ClaimDuringTransferReceiver {
    AlphaVault public immutable vault;
    bool public claimSucceeded;

    constructor(AlphaVault _vault) {
        vault = _vault;
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata) external returns (bytes4) {
        try vault.claimTao(id, payable(address(this))) {
            claimSucceeded = true;
        } catch { }
        return this.onERC1155Received.selector;
    }

    receive() external payable { }
}

contract ClaimReentrantReceiver {
    AlphaVault private immutable vault;
    uint256 private immutable tokenId;
    bytes public reentryError;
    bool public reentrySucceeded;

    constructor(AlphaVault target, uint256 id) {
        vault = target;
        tokenId = id;
    }

    receive() external payable {
        try vault.claimTao(tokenId, payable(address(this))) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            reentryError = reason;
        }
    }
}

contract QuoteProbeReceiver {
    AlphaVault private immutable VAULT;
    AlphaVaultLens private immutable LENS;
    uint256 private _tokenId;
    address private _holder;
    uint256 private _holderShares;
    address private _sink;

    uint256 public payoutQuote;
    uint256 public payoutClaim;
    uint256 public payoutSupply;
    uint256 public payoutHeadroom;
    bool public refundSeen;
    uint256 public refundQuote;
    uint256 public refundClaim;
    uint256 public refundHeadroom;

    constructor(AlphaVault vault, AlphaVaultLens lens) {
        VAULT = vault;
        LENS = lens;
    }

    function watch(uint256 tokenId, address holder, uint256 holderShares) external {
        _tokenId = tokenId;
        _holder = holder;
        _holderShares = holderShares;
    }

    function forwardRefundsTo(address sink) external {
        _sink = sink;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        if (_holder != address(0)) {
            refundSeen = true;
            (refundQuote,) = LENS.previewUnwrap(_tokenId, _holderShares);
            refundClaim = LENS.claimableTaoOf(_holder, _tokenId);
            refundHeadroom = _headroom();
            if (_sink != address(0)) {
                VAULT.safeTransferFrom(address(this), _sink, _tokenId, VAULT.balanceOf(address(this), _tokenId), "");
            }
        }
        return this.onERC1155Received.selector;
    }

    receive() external payable {
        (payoutQuote,) = LENS.previewUnwrap(_tokenId, _holderShares);
        payoutClaim = LENS.claimableTaoOf(_holder, _tokenId);
        payoutSupply = VAULT.totalSupply(_tokenId);
        payoutHeadroom = _headroom();
    }

    function _headroom() private view returns (uint256) {
        return VAULT.subnetClone(_tokenId).balance - VAULT.taoLiability(_tokenId);
    }
}
