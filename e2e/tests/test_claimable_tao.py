"""Scenario: TAO the chain strands on the vault becomes claimable, and the loss is written off.

When the chain's dust threshold is raised by governance, small stake entries
are force-sold and the vault's subnet account receives native TAO that no
vault operation paid out. The vault must credit the two holders present at
that moment their pro-rata slice and let each withdraw it.

The threshold raise clears sub-threshold nominations on EVERY subnet and
force-sells the vault's whole (deliberately tiny) position. Nothing on chain
records that as the cause, and a hotkey swap whose edge the chain has since
dropped looks identical, so the vault will not guess: anyone can put the loss
on file, the exits stay shut for the recovery window, and once it expires a
sync writes the deficit off and parks the empty position. The scenario deploys
with a short window so it can wait one out.
"""
import pytest

from alpha_e2e import chain, checks, config, extrinsics, incidents
from alpha_e2e.substrate import h160_to_ss58

HOLDERS = (
    (config.WRAPPER_USER_ADDRESS, config.WRAPPER_USER_PRIVATE_KEY),
    (config.SECOND_HOLDER_ADDRESS, config.SECOND_HOLDER_PRIVATE_KEY),
)


@pytest.fixture(scope="session")
def recovery_window():
    return config.SHORT_RECOVERY_WINDOW_SECONDS


@pytest.mark.scenario
def test_root_sweep_tao_becomes_claimable_and_the_loss_is_written_off(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    hotkey_ss58 = env.subnet_hotkey_ss58s(0)[0]
    extrinsics.fund_account(h160_to_ss58(config.SECOND_HOLDER_ADDRESS), 10 * config.RAO_PER_TAO)

    _, floor_boundary_alpha = env.floor_boundary(netuid, env.chain_min_stake_tao())
    env.deposit_and_wrap(
        netuid, hotkeys[0], hotkey_ss58, floor_boundary_alpha * 3 // 2, 1_500_000, "Sweep: first holder's wrap failed",
    )
    second_wrap = env.deposit_and_wrap(
        netuid, hotkeys[0], hotkey_ss58, floor_boundary_alpha * 3 // 2, 1_500_000, "Sweep: second holder's wrap failed",
        user=config.SECOND_HOLDER_ADDRESS, private_key=config.SECOND_HOLDER_PRIVATE_KEY,
    )
    checks.assert_wrap_kept_value_per_share(env, token_id, second_wrap, hotkeys, "Sweep: second holder's wrap")
    clone_evm = env.clone_address(token_id)
    clone_coldkey = env.clone_coldkey(token_id)
    recorded_backing = env.total_stake_across(
        clone_coldkey, netuid, hotkeys, chain.receipt_block_number(second_wrap, "Sweep: second wrap"),
    )
    supply = env.vault_total_supply(token_id)
    holder_shares = {address: env.vault_shares(token_id, address) for address, _ in HOLDERS}
    assert sum(holder_shares.values()) == supply, f"the two holders should hold all {supply} shares"
    assert chain.cast_balance_wei(clone_evm) == 0, "the clone should hold no TAO before the sweep"

    def claimable_tao(holder: str) -> int:
        return int(chain.cast_call(
            env.lens_address, "claimableTaoOf(address,uint256)(uint256)", holder, token_id,
        ))

    with incidents.dust_threshold_raised(incidents.RAISED_THRESHOLD_FACTOR):
        stranded = chain.cast_balance_wei(clone_evm)
        print(f"  Clearing pass stranded {stranded} wei on the subnet clone")
        assert stranded > 0, "expected the clearing pass to strand TAO on the clone"

        claimed_total = 0
        for holder, private_key in HOLDERS:
            claimable = claimable_tao(holder)
            checks.assert_floored_pro_rata(
                claimable, stranded, holder_shares[holder], supply, config.WEI_PER_RAO,
                f"Sweep: {holder}'s claim should be their slice of the stranded TAO, in whole RAO", floors=2,
            )
            balance_before = chain.cast_balance_wei(holder)
            receipt = env.vault_send(
                1_500_000, "Sweep: claim failed", "claimTao(uint256,address)", token_id, holder,
                private_key=private_key,
            )
            delivered = checks.reconstructed_payout(
                balance_before, chain.cast_balance_wei(holder), receipt, f"Sweep: {holder}'s claim payout",
            )
            assert delivered == claimable, f"{holder}: delivered {delivered} != quoted {claimable}"
            remaining = claimable_tao(holder)
            assert remaining == 0, f"{holder}: quote not cleared after claim: {remaining}"
            claimed_total += delivered
        assert chain.cast_balance_wei(clone_evm) == stranded - claimed_total, (
            f"the clone paid {stranded - chain.cast_balance_wei(clone_evm)} wei for {claimed_total} wei of claims"
        )

    # A share remainder of the sold nomination can grow back to dust with later emissions.
    assert env.total_stake_across(clone_coldkey, netuid, hotkeys) <= config.ROUNDING_DUST_TOTAL_RAO, (
        "the clearing pass left clone stake"
    )
    assert not env.backing_intact(token_id), "the swept position must read short"

    declared_at = incidents.declare_shortfall(env, token_id, "Sweep")
    deadline = env.write_off_deadline(token_id)
    assert deadline == declared_at + config.SHORT_RECOVERY_WINDOW_SECONDS, (
        f"write-off deadline {deadline}; expected the declaring block's {declared_at} "
        f"+ {config.SHORT_RECOVERY_WINDOW_SECONDS} s"
    )
    env.assert_vault_reverts_with(
        "ShortfallOnFile()", 2_500_000, "Sweep: the exit should be refused while the recovery window runs",
        "unwrapForTao(uint256,uint256,uint256)", token_id, holder_shares[config.WRAPPER_USER_ADDRESS], 0,
    )

    write_off = incidents.write_off_when_due(env, token_id, deadline, "Sweep")
    assert write_off.expected == recorded_backing, (
        f"the write-off expected {write_off.expected} RAO; the wraps recorded {recorded_backing}"
    )
    assert write_off.located == 0, f"the write-off located {write_off.located} RAO of a fully swept position"
    assert env.awaiting_attestation(token_id), "the written-off position should rest on the parking hotkey"
    assert env.write_off_deadline(token_id) == 0, "nothing should be on file after the write-off"

    for holder, private_key in HOLDERS:
        env.vault_send(
            2_000_000, f"Sweep: {holder} could not retire written-off shares",
            "unwrap(uint256,uint256,bytes32,uint256)", token_id, holder_shares[holder], env.wrapper_substrate_coldkey, 0,
            private_key=private_key,
        )
    assert env.vault_total_supply(token_id) == 0, "the written-off position kept outstanding shares"
    assert not env.awaiting_attestation(token_id), "an empty position should not stay parked"
