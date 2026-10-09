"""Scenario: TAO the chain strands on the vault becomes claimable, and the loss is written off.

When the chain's dust threshold is raised by governance, small stake entries
are force-sold and the vault's subnet account receives native TAO that no
vault operation paid out. The vault must credit exactly the holders present
at that moment and let them withdraw it.

The threshold raise clears sub-threshold nominations on EVERY subnet and
force-sells the vault's whole (deliberately tiny) position. Nothing on chain
records that as the cause, and a hotkey swap whose edge the chain has since
dropped looks identical, so the vault will not guess: anyone can put the loss
on file, the exits stay shut for the recovery window, and once it expires a
sync writes the deficit off and parks the empty position. The scenario deploys
with a short window so it can wait one out.
"""
import pytest

from alpha_e2e import chain, checks, config, extrinsics

# The mainnet factor: threshold = 0.002 TAO * factor / 1e6 = 0.02 TAO, far above
# the position the deposit below leaves on its validator.
RAISED_THRESHOLD_FACTOR = 10_000_000
WRITE_OFF_WINDOW_SECONDS = 120


@pytest.fixture(scope="session")
def recovery_window():
    return WRITE_OFF_WINDOW_SECONDS


@pytest.mark.scenario
def test_root_sweep_tao_becomes_claimable_and_the_loss_is_written_off(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)

    # A deposit sized far below the raised threshold, but comfortably above the deposit floor.
    _, floor_boundary_alpha = env.floor_boundary(netuid, env.chain_min_stake_tao())
    wrap_receipt = env.deposit_and_wrap(
        netuid, hotkeys[0], env.hotkey_ss58s[0], floor_boundary_alpha * 3 // 2, 1_500_000, "Sweep: wrap failed",
    )
    clone_evm = env.clone_address(token_id)
    clone_coldkey = env.clone_coldkey(token_id)
    recorded_backing = env.total_stake_across(
        clone_coldkey, netuid, hotkeys, chain.receipt_block_number(wrap_receipt, "Sweep: wrap"),
    )
    clone_balance_before = chain.cast_balance_wei(clone_evm)

    def claimable_tao() -> int:
        return int(chain.cast_call(
            env.lens_address, "claimableTaoOf(address,uint256)(uint256)",
            config.WRAPPER_USER_ADDRESS, token_id,
        ))

    previous_factor = extrinsics.get_nominator_min_required_stake()
    extrinsics.set_nominator_min_required_stake(RAISED_THRESHOLD_FACTOR)
    try:
        stranded = chain.cast_balance_wei(clone_evm) - clone_balance_before
        print(f"  Clearing pass stranded {stranded} wei on the subnet clone")
        assert stranded > 0, "expected the clearing pass to strand TAO on the clone"

        # The view quotes at RAO granularity, so it can sit up to one RAO below the raw
        # stranded amount (index flooring plus the RAO floor of the quote).
        claimable = claimable_tao()
        assert claimable % config.WEI_PER_RAO == 0, f"claimable {claimable} is not RAO-granular"
        assert 0 <= stranded - claimable <= config.WEI_PER_RAO, (
            f"claimable {claimable} != stranded {stranded} floored to the RAO"
        )

        user_balance_before = env.user_tao_wei()
        receipt = env.vault_send(
            1_500_000, "Sweep: claim failed",
            "claimTao(uint256,address)", token_id, config.WRAPPER_USER_ADDRESS,
        )
        delivered = checks.reconstructed_payout(
            user_balance_before, env.user_tao_wei(), receipt, "Sweep: claim payout",
        )
        # The quote is a commitment: the claim delivers exactly what the view promised, and the
        # sub-RAO remainder stays reserved for the claimant below the quote's one-RAO floor.
        assert delivered == claimable, f"delivered {delivered} != quoted {claimable}"
        remaining = claimable_tao()
        assert remaining == 0, f"quote not cleared after claim: {remaining}"
    finally:
        # A raise here would mask the test's own assertion error; report and move on instead.
        try:
            extrinsics.set_nominator_min_required_stake(previous_factor)
        except Exception as restore_error:  # noqa: BLE001
            print(f"  WARNING: dust threshold not restored to {previous_factor}: {restore_error}")

    # The clearing pass sold the whole nomination, so the record expects alpha that is gone; a share
    # remainder can grow back to dust with later emissions.
    assert env.total_stake_across(clone_coldkey, netuid, hotkeys) <= config.ROUNDING_DUST_TOTAL_RAO, (
        "the clearing pass left clone stake"
    )
    assert not env.backing_intact(token_id), "the swept position must read short"

    # Any caller can put the loss on file; the window runs from that block.
    declare_receipt = env.sync_backing(token_id, label="syncBacking [declare]")
    declared_at = chain.block_timestamp(chain.receipt_block_number(declare_receipt, "Sweep: declare"))
    deadline = env.write_off_deadline(token_id)
    assert deadline == declared_at + WRITE_OFF_WINDOW_SECONDS, (
        f"write-off deadline {deadline}; expected the declaring block's {declared_at} + {WRITE_OFF_WINDOW_SECONDS} s"
    )
    all_shares = env.vault_shares(token_id)
    env.assert_vault_reverts_with(
        "ShortfallOnFile()", 2_500_000, "Sweep: the exit should be refused while the recovery window runs",
        "unwrapForTao(uint256,uint256,uint256)", token_id, all_shares, 0,
    )

    chain.wait_for_timestamp(deadline, timeout=2 * WRITE_OFF_WINDOW_SECONDS)
    write_off_receipt = env.sync_backing(token_id, label="syncBacking [write off]")
    expected = chain.event_word(write_off_receipt, "BackingWrittenOff(uint256,uint256,uint256)", 0, "Sweep: write-off")
    located = chain.event_word(write_off_receipt, "BackingWrittenOff(uint256,uint256,uint256)", 1, "Sweep: write-off")
    assert expected == recorded_backing, (
        f"the write-off expected {expected} RAO; the wrap recorded {recorded_backing}"
    )
    assert located == 0, f"the write-off located {located} RAO of a fully swept position"
    assert env.awaiting_attestation(token_id), "the written-off position should rest on the parking hotkey"
    assert env.write_off_deadline(token_id) == 0, "nothing should be on file after the write-off"

    # With nothing left to deliver, a zero floor burns the shares and closes the position.
    env.vault_send(
        2_000_000, "Sweep: the holder could not retire written-off shares",
        "unwrap(uint256,uint256,bytes32,uint256)", token_id, all_shares, env.wrapper_substrate_coldkey, 0,
    )
    assert env.vault_total_supply(token_id) == 0, "the written-off position kept outstanding shares"
    assert not env.awaiting_attestation(token_id), "an empty position should not stay parked"
