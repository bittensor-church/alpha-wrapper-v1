"""Chain-side incidents the recovery scenarios stage against a vault position."""
from dataclasses import dataclass

from . import checks, config, extrinsics
from .environment import Environment
from .substrate import h160_to_ss58

STRANGER_URI = "//Bob"
# One association, one per-subnet swap fee and transaction fees.
STRANGER_FUNDING_RAO = 2_000_000_000
KEEPER_URI = "//EntryKeeper"
RETURNER_URI = "//Returner"


@dataclass(frozen=True)
class Stranding:
    lost_pubkey: str
    lost_ss58: str
    successor_pubkey: str
    successor_ss58: str
    stranger_ss58: str
    backing_before: int


def cut_trail(
    env: Environment, subnet_index: int, validator_index: int,
    successor_uri: str, junk_uri: str, context: str,
) -> Stranding:
    """Strand the vault's alpha behind a hotkey swap whose trail a stranger cuts."""
    netuid = env.netuids[subnet_index]
    token_id = env.token_ids[subnet_index]
    position = subnet_index * config.VALIDATORS_PER_SUBNET + validator_index
    lost_pubkey = env.hotkey_pubkeys[position]
    lost_ss58 = env.hotkey_ss58s[position]
    clone_coldkey = env.clone_coldkey(token_id)
    backing_before = env.total_stake_across(clone_coldkey, netuid, env.subnet_hotkey_pubkeys(subnet_index))
    assert env.stake(lost_pubkey, clone_coldkey, netuid) > 0, (
        f"{context}: nothing sits under the hotkey about to move"
    )

    successor_ss58 = extrinsics.keypair_ss58(successor_uri)
    successor_pubkey = extrinsics.keypair_pubkey(successor_uri)
    extrinsics.swap_hotkey(lost_ss58, successor_ss58)
    assert extrinsics.hotkey_owner(lost_ss58) == "", f"{context}: the swap should leave the old hotkey unowned"
    assert env.stake(successor_pubkey, clone_coldkey, netuid) > 0, f"{context}: the alpha did not follow the swap"
    assert env.backing_intact(token_id), f"{context}: a plain swap is followed and is not a loss"

    stranger_ss58 = extrinsics.keypair_ss58(STRANGER_URI)
    junk_ss58 = extrinsics.keypair_ss58(junk_uri)
    extrinsics.fund_account(stranger_ss58, STRANGER_FUNDING_RAO)
    extrinsics.associate_hotkey(junk_ss58, signer_uri=STRANGER_URI)
    extrinsics.swap_hotkey_on_subnet(junk_ss58, lost_ss58, netuid, signer_uri=STRANGER_URI)
    assert extrinsics.hotkey_owner(lost_ss58) == stranger_ss58, f"{context}: the stranger did not take the hotkey"
    assert env.backing_intact(token_id), f"{context}: with the edge gone the vault finds its alpha on the clone's list"

    return Stranding(lost_pubkey, lost_ss58, successor_pubkey, successor_ss58, stranger_ss58, backing_before)


@dataclass(frozen=True)
class Sweep:
    """A position the chain sold through its nominator-minimum sweep. `listed` is the rotated-out
    validator a gift keeps on the clone's staking list, where the alpha can come back."""
    attested_pubkey: str
    attested_ss58: str
    listed_pubkey: str
    listed_ss58: str
    swept_rao: int
    backing_before: int


def _threshold_factor(env: Environment, threshold_rao: int) -> int:
    """The sweep threshold is the chain's minimum stake scaled by a factor over 1e6."""
    minimum = env.chain_min_stake_tao()
    return (threshold_rao * 1_000_000 + minimum - 1) // minimum


def sweep(env: Environment, subnet_index: int, context: str) -> Sweep:
    """Lose the position the one way the chain takes alpha the list search cannot find: rotate it onto
    the subnet's second validator, keep the first listed with a gift under it on another subnet, then raise
    the nominator minimum over the position so the chain sells it."""
    netuid = env.netuids[subnet_index]
    other_netuid = env.netuids[(subnet_index + 1) % len(env.netuids)]
    token_id = env.token_ids[subnet_index]
    position = subnet_index * config.VALIDATORS_PER_SUBNET
    listed_pubkey, listed_ss58 = env.hotkey_pubkeys[position], env.hotkey_ss58s[position]
    attested_pubkey, attested_ss58 = env.hotkey_pubkeys[position + 1], env.hotkey_ss58s[position + 1]
    clone_ss58 = h160_to_ss58(env.clone_address(token_id))
    clone_coldkey = env.clone_coldkey(token_id)
    backing_before = env.vault_total_stake(token_id)
    # Half again over the position's value: the chain prices the sweep with its own rounding.
    threshold_rao = env.alpha_value_tao(netuid, backing_before) * 3 // 2 + 1

    keeper_ss58 = extrinsics.keypair_ss58(KEEPER_URI)
    extrinsics.fund_account(keeper_ss58, 8 * threshold_rao + config.RAO_PER_TAO)
    extrinsics.add_stake(listed_ss58, other_netuid, 6 * threshold_rao, signer_uri=KEEPER_URI)
    _, gift = env.floor_boundary(other_netuid, 3 * threshold_rao)
    extrinsics.transfer_stake(clone_ss58, listed_ss58, other_netuid, gift, signer_uri=KEEPER_URI)
    kept = env.alpha_value_tao(other_netuid, env.stake(listed_pubkey, clone_coldkey, other_netuid))
    assert kept > threshold_rao, f"{context}: the gift worth {kept} RAO would not survive a sweep at {threshold_rao}"

    env.set_validator(netuid, attested_pubkey)
    env.vault_send(
        4_000_000, f"{context}: the rotation rebalance failed", "rebalance(uint256)", netuid,
        label="rebalance [rotate]",
    )
    assert env.stake(listed_pubkey, clone_coldkey, netuid) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"{context}: the rotation left alpha behind"
    )
    swept_rao = env.stake(attested_pubkey, clone_coldkey, netuid)
    assert swept_rao > 0, f"{context}: the rotation moved nothing"

    previous = extrinsics.get_nominator_min_required_stake()
    extrinsics.set_nominator_min_required_stake(_threshold_factor(env, threshold_rao))
    extrinsics.set_nominator_min_required_stake(previous)
    assert env.stake(attested_pubkey, clone_coldkey, netuid) == 0, f"{context}: the sweep left the position"
    assert env.stake(listed_pubkey, clone_coldkey, other_netuid) > 0, f"{context}: the sweep took the gift"
    assert not env.backing_intact(token_id), f"{context}: a swept position must read short"
    return Sweep(attested_pubkey, attested_ss58, listed_pubkey, listed_ss58, swept_rao, backing_before)


def _return_alpha(env: Environment, token_id: int, netuid: int, swept: Sweep, context: str) -> None:
    """A stranger buys the swept amount back and transfers it to the clone under the listed validator."""
    returner_ss58 = extrinsics.keypair_ss58(RETURNER_URI)
    returner_pubkey = extrinsics.keypair_pubkey(RETURNER_URI)
    budget = 3 * env.alpha_value_tao(netuid, swept.swept_rao) + config.RAO_PER_TAO
    extrinsics.fund_account(returner_ss58, budget + config.RAO_PER_TAO)
    extrinsics.add_stake(swept.listed_ss58, netuid, budget, signer_uri=RETURNER_URI)
    bought = env.stake(swept.listed_pubkey, returner_pubkey, netuid)
    assert bought >= swept.swept_rao, f"{context}: the returner bought {bought} alpha RAO, short of {swept.swept_rao}"
    extrinsics.transfer_stake(
        h160_to_ss58(env.clone_address(token_id)), swept.listed_ss58, netuid, swept.swept_rao, signer_uri=RETURNER_URI,
    )


def park(env: Environment, token_id: int, swept: Sweep, context: str) -> int:
    """The watcher's answer to a shortfall: declare, recover what `scripts/find_strays.py`
    reports through its `--recover` flag, finalize. The alpha comes back under a listed hotkey the
    record does not name."""
    netuid = env.netuids[env.token_ids.index(token_id)]
    clone_coldkey = env.clone_coldkey(token_id)

    env.sync_backing(token_id, label="syncBacking [declare]")
    assert env.write_off_deadline(token_id) > 0, f"{context}: the shortfall should be on file with a deadline"
    _return_alpha(env, token_id, netuid, swept, context)
    strays = checks.find_strays(env, token_id, recover=True)
    assert [row["hotkey"].lower() for row in strays] == [swept.listed_pubkey.lower()], (
        f"{context}: find_strays should report exactly the listed validator, got {strays}"
    )
    assert strays[0]["dry_run"] == "ok", f"{context}: the returned alpha should be recoverable, got {strays}"
    assert int(strays[0]["stake_rao"]) >= swept.swept_rao - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        f"{context}: the return fell short, got {strays}"
    )
    assert checks.find_strays(env, token_id) == [], f"{context}: nothing should be left outside the record"

    env.sync_backing(token_id, label="syncBacking [finalize]")
    parked = env.stake(env.parking_hotkey(), clone_coldkey, netuid)
    assert parked >= swept.backing_before - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        f"{context}: the parking hotkey holds {parked} against {swept.backing_before} before the incident"
    )
    assert env.awaiting_attestation(token_id), f"{context}: the position should wait for the registry owner"
    assert env.backing_intact(token_id), f"{context}: parked backing accounts for itself"
    assert env.write_off_deadline(token_id) == 0, f"{context}: nothing should be on file any more"
    assert len(extrinsics.staking_hotkeys(h160_to_ss58(env.clone_address(token_id)))) >= 2, (
        f"{context}: the gift should keep the rotated-out validator listed beside the parking hotkey"
    )
    return parked
