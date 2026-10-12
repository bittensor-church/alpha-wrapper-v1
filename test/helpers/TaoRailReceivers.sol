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

/// @dev Re-enters `target` once from its TAO payout and captures the error, so tests can tell the guard
///      from incidental failures.
contract ReentrantReceiver {
    address private target;
    bytes private reentry;
    bytes public reentryError;
    bool public reentrySucceeded;
    bool private entered;

    function arm(address _target, bytes calldata _reentry) external {
        target = _target;
        reentry = _reentry;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        (bool ok, bytes memory result) = target.call(reentry);
        if (ok) {
            reentrySucceeded = true;
        } else {
            reentryError = result;
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
