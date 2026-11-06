// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IStaking, STAKING_PRECOMPILE } from "../interfaces/IStaking.sol";
import { IAlphaVaultAbi } from "../interfaces/IAlphaVaultAbi.sol";
import { CloneFactory } from "../CloneFactory.sol";
import { CloneOwner } from "../CloneOwner.sol";
import { SubnetClone } from "../SubnetClone.sol";
import { VaultMath } from "./VaultMath.sol";
import { VaultReads } from "./VaultReads.sol";

interface IVaultCloneFactory {
    function cloneFactory() external view returns (CloneFactory);
}

library StakeOps {
    function taoValue(uint256 alphaAmount, uint256 alphaPriceE18) internal pure returns (uint256) {
        return Math.mulDiv(alphaAmount, alphaPriceE18, VaultMath.ALPHA_PRICE_SCALE);
    }

    /// @dev The only exposed minimum is for unstakes; using it for transfers/moves is conservative.
    function minStakeTao() internal view returns (uint256) { return IStaking(STAKING_PRECOMPILE).getDefaultMinStake(); }

    /// @notice Claims an ownerless hotkey for the clone's owner contract; an existing owner stays untouched.
    /// @dev The chain refuses to move stake through a hotkey with no owner record.
    function ensureHotkeyHasOwner(address clone, bytes32 hotkey) internal {
        if (VaultReads.hasOwner(hotkey)) return;
        CloneFactory factory = IVaultCloneFactory(address(this)).cloneFactory();
        CloneOwner(factory.cloneOwnerOf(VaultReads.coldkeyOf(clone))).tryAssociateHotkey(hotkey);
    }

    function moveWithinListCap(address clone, bytes32 coldkey, bytes32 fromHotkey, bytes32 toHotkey, uint16 netuid, uint256 amount,
        bytes32 parking) internal {
        if (!VaultReads.stakingListAdmits(coldkey, toHotkey, netuid, parking)) revert IAlphaVaultAbi.StakingListFull();
        moveToListedHotkey(clone, fromHotkey, toHotkey, netuid, amount);
    }

    function moveToListedHotkey(address clone, bytes32 fromHotkey, bytes32 toHotkey, uint16 netuid, uint256 amount) internal {
        ensureHotkeyHasOwner(clone, fromHotkey);
        ensureHotkeyHasOwner(clone, toHotkey);
        SubnetClone(clone).moveStake(fromHotkey, toHotkey, netuid, amount);
    }

    function flush(address clone, bytes32 hotkey, bytes32 destinationColdkey, uint16 netuid, uint256 amount) internal {
        ensureHotkeyHasOwner(clone, hotkey);
        SubnetClone(clone).flush(destinationColdkey, hotkey, netuid, amount);
    }

    function sell(address clone, bytes32 hotkey, uint16 netuid, uint256 amount) internal {
        ensureHotkeyHasOwner(clone, hotkey);
        SubnetClone(clone).sellAlphaForTao(hotkey, netuid, amount);
    }

    /// @dev Use where the amount must clear the floor at the price just read, such as sizing a payout.
    ///      A rounded-down price can reject a valid amount; zero proves nothing and full unstakes bypass this.
    function isBelowFloorAtReadPrice(uint256 alphaAmount, uint256 alphaPriceE18) internal view returns (bool) {
        return alphaPriceE18 != 0 && taoValue(alphaAmount, alphaPriceE18) < minStakeTao();
    }

    /// @dev Use where refusing a movable amount would be worse than attempting it: rejects only an amount
    ///      below the floor even at the upper bound hidden by price rounding.
    function isBelowFloorAtAnyPrice(uint256 alphaAmount, uint256 alphaPriceE18) internal view returns (bool) {
        return alphaPriceE18 != 0 && taoValue(alphaAmount, alphaPriceE18 + VaultMath.ALPHA_PRICE_QUANTUM_E18) < minStakeTao();
    }
}
