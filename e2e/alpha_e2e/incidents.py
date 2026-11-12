"""Chain-side incidents the recovery scenarios stage against a vault position.

The staging helpers return what they observed and assert only that their own staging took;
the scenarios assert the vault's answer, the shared ones through `assert_watcher_parked`.
"""
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Iterator, List

from . import chain, checks, config, extrinsics
from .environment import Environment
from .substrate import account_id_to_ss58, h160_to_ss58

STRANGER_URI = "//Bob"
# One association, one per-subnet swap fee and transaction fees.
STRANGER_FUNDING_RAO = 2_000_000_000
KEEPER_URI = "//EntryKeeper"
RETURNER_URI = "//Returner"
# The chain's sweep threshold is its minimum stake (0.002 TAO) times this factor over 1e6: 0.02 TAO.
RAISED_THRESHOLD_FACTOR = 10_000_000


@contextmanager
def dust_threshold_raised(factor: int) -> Iterator[None]:
    """Raise the nominator dust threshold, which force-sells every nomination below it on every
    subnet in the raising block, and restore the previous factor on the way out."""
    previous = extrinsics.get_nominator_min_required_stake()
    extrinsics.set_nominator_min_required_stake(factor)
    try:
        yield
    finally:
        try:
            extrinsics.set_nominator_min_required_stake(previous)
        except extrinsics.ExtrinsicError as restore_error:
            print(f"  WARNING: dust threshold not restored to {previous}: {restore_error}")


def declare_shortfall(env: Environment, token_id: int, context: str) -> int:
    """Put the token's shortfall on file; returns the declaring block's timestamp."""
    receipt = env.sync_backing(token_id, label="syncBacking [declare]")
    return chain.block_timestamp(chain.receipt_block_number(receipt, f"{context}: declare"))


@dataclass(frozen=True)
class WriteOff:
    """What `BackingWrittenOff` reports: the alpha the record expected and the alpha located."""
    expected: int
    located: int
    receipt: dict


def write_off_when_due(env: Environment, token_id: int, deadline: int, context: str) -> WriteOff:
    """Wait for the first block stamped at the write-off deadline, then sync, which writes the
    remaining deficit off."""
    remaining_seconds = max(deadline - chain.block_timestamp(), 0)
    chain.wait_for_timestamp(deadline, timeout=2 * remaining_seconds + config.BLOCK_TIMEOUT_SECONDS)
    receipt = env.sync_backing(token_id, label="syncBacking [write off]")
    event = "BackingWrittenOff(uint256,uint256,uint256)"
    return WriteOff(
        chain.event_word(receipt, event, 0, f"{context}: write-off"),
        chain.event_word(receipt, event, 1, f"{context}: write-off"),
        receipt,
    )


@dataclass(frozen=True)
class Stranding:
    lost_pubkey: str
    lost_ss58: str
    successor_pubkey: str
    successor_ss58: str


def swap_validator_hotkey(
    env: Environment, subnet_index: int, validator_index: int, successor_uri: str, context: str,
) -> Stranding:
    """The validator swaps its hotkey on every subnet, carrying the clone's alpha to the successor and
    leaving the old hotkey unowned."""
    netuid = env.netuids[subnet_index]
    lost_pubkey = env.subnet_hotkey_pubkeys(subnet_index)[validator_index]
    lost_ss58 = env.subnet_hotkey_ss58s(subnet_index)[validator_index]
    clone_coldkey = env.clone_coldkey(env.token_ids[subnet_index])
    assert env.stake(lost_pubkey, clone_coldkey, netuid) > 0, (
        f"{context}: nothing sits under the hotkey about to move"
    )
    successor_ss58 = extrinsics.keypair_ss58(successor_uri)
    successor_pubkey = extrinsics.keypair_pubkey(successor_uri)
    extrinsics.swap_hotkey(lost_ss58, successor_ss58)
    assert extrinsics.hotkey_owner(lost_ss58) == "", f"{context}: the swap should leave the old hotkey unowned"
    assert env.stake(successor_pubkey, clone_coldkey, netuid) > 0, f"{context}: the alpha did not follow the swap"
    return Stranding(lost_pubkey, lost_ss58, successor_pubkey, successor_ss58)


def cut_trail(env: Environment, netuid: int, stranding: Stranding, junk_uri: str, context: str) -> None:
    """A stranger claims the vacated hotkey and swaps a junk hotkey onto it on `netuid`, which erases
    the edge the vault follows."""
    stranger_ss58 = extrinsics.keypair_ss58(STRANGER_URI)
    junk_ss58 = extrinsics.keypair_ss58(junk_uri)
    extrinsics.fund_account(stranger_ss58, STRANGER_FUNDING_RAO)
    extrinsics.associate_hotkey(junk_ss58, signer_uri=STRANGER_URI)
    extrinsics.swap_hotkey_on_subnet(junk_ss58, stranding.lost_ss58, netuid, signer_uri=STRANGER_URI)
    assert extrinsics.hotkey_owner(stranding.lost_ss58) == stranger_ss58, (
        f"{context}: the stranger did not take the hotkey"
    )


@dataclass(frozen=True)
class Sweep:
    """A position the chain sold through its nominator-minimum sweep. `listed` is the rotated-out
    validator a gift keeps on the clone's staking list, where the alpha can come back. `swept_rao`
    is what the record held under the attested hotkey when the sweep took it."""
    attested_pubkey: str
    attested_ss58: str
    listed_pubkey: str
    listed_ss58: str
    swept_rao: int


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
    listed_pubkey, attested_pubkey = env.subnet_hotkey_pubkeys(subnet_index)[:2]
    listed_ss58, attested_ss58 = env.subnet_hotkey_ss58s(subnet_index)[:2]
    clone_ss58 = h160_to_ss58(env.clone_address(token_id))
    clone_coldkey = env.clone_coldkey(token_id)
    position_rao = env.total_stake_across(clone_coldkey, netuid, env.subnet_hotkey_pubkeys(subnet_index))
    # Half again over the position's value: the chain prices the sweep with its own rounding.
    threshold_rao = env.alpha_value_tao(netuid, position_rao) * 3 // 2 + 1

    keeper_ss58 = extrinsics.keypair_ss58(KEEPER_URI)
    extrinsics.fund_account(keeper_ss58, 8 * threshold_rao + config.RAO_PER_TAO)
    extrinsics.add_stake(listed_ss58, other_netuid, 6 * threshold_rao, signer_uri=KEEPER_URI)
    _, gift = env.floor_boundary(other_netuid, 3 * threshold_rao)
    extrinsics.transfer_stake(clone_ss58, listed_ss58, other_netuid, gift, signer_uri=KEEPER_URI)
    kept = env.alpha_value_tao(other_netuid, env.stake(listed_pubkey, clone_coldkey, other_netuid))
    assert kept > threshold_rao, f"{context}: the gift worth {kept} RAO would not survive a sweep at {threshold_rao}"

    env.set_validator(netuid, attested_pubkey)
    rotation = env.vault_send(
        4_000_000, f"{context}: the rotation rebalance failed", "rebalance(uint256)", netuid,
        label="rebalance [rotate]",
    )
    rotation_block = chain.receipt_block_number(rotation, f"{context}: rotation")
    assert env.stake(listed_pubkey, clone_coldkey, netuid, rotation_block) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"{context}: the rotation left alpha behind"
    )
    swept_rao = env.stake(attested_pubkey, clone_coldkey, netuid, rotation_block)
    assert swept_rao > 0, f"{context}: the rotation moved nothing"

    previous_factor = extrinsics.get_nominator_min_required_stake()
    extrinsics.set_nominator_min_required_stake(_threshold_factor(env, threshold_rao))
    extrinsics.set_nominator_min_required_stake(previous_factor)
    assert env.stake(attested_pubkey, clone_coldkey, netuid) == 0, f"{context}: the sweep left the position"
    assert env.stake(listed_pubkey, clone_coldkey, other_netuid) > 0, f"{context}: the sweep took the gift"
    return Sweep(attested_pubkey, attested_ss58, listed_pubkey, listed_ss58, swept_rao)


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


@dataclass(frozen=True)
class Parking:
    """What the watcher saw while parking a swept position: the write-off deadline the declaration put
    on file and the block it was declared at, the piles `scripts/find_strays.py --recover` reported and
    the ones a dry run reports after it, and the alpha on the parking hotkey once finalized."""
    deadline: int
    declared_at: int
    recovered: List[dict]
    left_out: List[dict]
    parked: int


def park(env: Environment, token_id: int, swept: Sweep, context: str) -> Parking:
    """The watcher's answer to a shortfall: declare, recover what `scripts/find_strays.py`
    reports through its `--recover` flag, finalize. The alpha comes back under a listed hotkey the
    record does not name."""
    netuid = env.netuid_of(token_id)
    declared_at = declare_shortfall(env, token_id, context)
    deadline = env.write_off_deadline(token_id)
    _return_alpha(env, token_id, netuid, swept, context)
    recovered = checks.find_strays(env, token_id, recover=True)
    left_out = checks.find_strays(env, token_id)
    env.sync_backing(token_id, label="syncBacking [finalize]")
    parked = env.stake(env.parking_hotkey(), env.clone_coldkey(token_id), netuid)
    return Parking(deadline, declared_at, recovered, left_out, parked)


def assert_watcher_parked(env: Environment, token_id: int, swept: Sweep, parking: Parking, context: str) -> None:
    """Assert the watcher's declaration started the default recovery window, the script found and
    recovered exactly the returned pile, and the finalized position rests on the parking hotkey,
    whole, waiting for the registry owner, with the gift keeping the rotated-out validator listed."""
    assert parking.deadline == parking.declared_at + config.RECOVERY_WINDOW_SECONDS, (
        f"{context}: deadline {parking.deadline}; expected the declaring block's {parking.declared_at} "
        f"+ {config.RECOVERY_WINDOW_SECONDS} s"
    )
    assert [row["hotkey"].lower() for row in parking.recovered] == [swept.listed_pubkey.lower()], (
        f"{context}: find_strays should report exactly the listed validator, got {parking.recovered}"
    )
    reported = int(parking.recovered[0]["stake_rao"])
    assert parking.recovered[0]["dry_run"] == "ok", f"{context}: the returned alpha should be recoverable"
    assert reported >= swept.swept_rao - config.ROUNDING_DUST_SLOT_RAO, (
        f"{context}: the stranger returned {swept.swept_rao} alpha RAO, the script found {reported}"
    )
    assert parking.left_out == [], f"{context}: nothing should be left outside the record, got {parking.left_out}"
    assert parking.parked >= reported - config.ROUNDING_DUST_SLOT_RAO, (
        f"{context}: the parking hotkey holds {parking.parked} alpha RAO of the {reported} recovered"
    )
    assert env.awaiting_attestation(token_id), f"{context}: the position should wait for the registry owner"
    assert env.backing_intact(token_id), f"{context}: parked backing accounts for itself"
    assert env.write_off_deadline(token_id) == 0, f"{context}: nothing should be on file any more"
    listed = set(extrinsics.staking_hotkeys(h160_to_ss58(env.clone_address(token_id))))
    parking_ss58 = account_id_to_ss58(bytes.fromhex(env.parking_hotkey().removeprefix("0x")))
    assert {swept.listed_ss58, parking_ss58} <= listed, (
        f"{context}: the clone should list the gifted validator and the parking hotkey, lists {listed}"
    )
