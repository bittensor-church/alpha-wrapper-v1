"""Scenario: a write-off with no share holders leaves the token open.

A stranger's crumb on another subnet keeps the attested validator on the clone's staking
list after the last holder exits, so anyone can still transfer a small amount of alpha to
the clone under that validator, and `rebalance` records it as backing. A
governance raise of the chain's dust threshold then force-sells that small nomination, so
the record expects alpha that is gone. Anyone declares the loss and, once the recovery
window expires, writes it off. Parking protects holders from dilution, and with no
holders there is nobody to protect: the write-off must leave the empty token open, so
the next deposit wraps without any registry update.
"""
import pytest

from alpha_e2e import chain, config, exits, extrinsics, substrate

STRANGER = "//EmptyTokenStranger"
STRANGER_FUNDING_RAO = 20 * config.RAO_PER_TAO

# Threshold = 0.002 TAO * factor / 1e6 = 0.02 TAO, far above the gift.
RAISED_THRESHOLD_FACTOR = 10_000_000
WRITE_OFF_WINDOW_SECONDS = 120


@pytest.fixture(scope="session")
def recovery_window():
    return WRITE_OFF_WINDOW_SECONDS


@pytest.mark.scenario
def test_write_off_at_zero_supply_reopens_deposits_without_registry_action(env):
    netuid, other_netuid = env.netuids[0], env.netuids[1]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    attested_hotkey, attested_ss58 = hotkeys[0], env.hotkey_ss58s[0]
    clone_coldkey = env.clone_coldkey(token_id)

    def registry_nonce() -> int:
        return int(chain.cast_call(env.validator_registry_address, "nonces(uint256)(uint256)", netuid))

    env.deposit_and_wrap(
        netuid, attested_hotkey, attested_ss58, config.DEPOSIT_RAO, 1_500_000, "Empty write-off: wrap failed",
    )
    clone_ss58 = substrate.h160_to_ss58(env.clone_address(token_id))
    stranger_ss58 = extrinsics.keypair_ss58(STRANGER)
    extrinsics.fund_account(stranger_ss58, STRANGER_FUNDING_RAO)
    extrinsics.add_stake(attested_ss58, other_netuid, 2 * config.RAO_PER_TAO, signer_uri=STRANGER)
    _, crumb = env.floor_boundary(other_netuid, 2 * env.chain_min_transfer_tao())
    extrinsics.transfer_stake(clone_ss58, attested_ss58, other_netuid, crumb, signer_uri=STRANGER)

    exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Empty write-off: the full exit failed", hotkeys=hotkeys,
    )
    assert env.vault_total_supply(token_id) == 0, "the full exit left shares outstanding"
    assert len(extrinsics.staking_hotkeys(clone_ss58)) == 1, "the crumb did not keep the validator listed"
    nonce_before = registry_nonce()

    # A gift sized above the chain's transfer minimum and far below the raised threshold.
    _, floor_boundary_alpha = env.floor_boundary(netuid, env.chain_min_stake_tao())
    gift = floor_boundary_alpha * 3 // 2
    extrinsics.transfer_stake(clone_ss58, attested_ss58, netuid, gift)
    rebalance_receipt = env.vault_send_between_epochs(
        netuid, 4_000_000, "Empty write-off: the recording rebalance failed", "rebalance(uint256)", netuid,
        label="rebalance [record gift]",
    )
    recorded = env.total_stake_across(
        clone_coldkey, netuid, hotkeys, chain.receipt_block_number(rebalance_receipt, "Empty write-off: rebalance"),
    )
    assert recorded >= gift - config.ROUNDING_DUST_TOTAL_RAO, (
        f"the vault recorded {recorded} RAO against a gift of {gift}"
    )

    previous_factor = extrinsics.get_nominator_min_required_stake()
    extrinsics.set_nominator_min_required_stake(RAISED_THRESHOLD_FACTOR)
    try:
        assert env.total_stake_across(clone_coldkey, netuid, hotkeys) <= config.ROUNDING_DUST_TOTAL_RAO, (
            "the clearing pass left clone stake"
        )
        assert not env.backing_intact(token_id), "the swept gift must read short"
    finally:
        # A raise here would mask the test's own assertion error; report and move on instead.
        try:
            extrinsics.set_nominator_min_required_stake(previous_factor)
        except Exception as restore_error:  # noqa: BLE001
            print(f"  WARNING: dust threshold not restored to {previous_factor}: {restore_error}")

    declare_receipt = env.sync_backing(token_id, label="syncBacking [declare]")
    declared_at = chain.block_timestamp(chain.receipt_block_number(declare_receipt, "Empty write-off: declare"))
    deadline = env.write_off_deadline(token_id)
    assert deadline == declared_at + WRITE_OFF_WINDOW_SECONDS, (
        f"write-off deadline {deadline}; expected the declaring block's {declared_at} + {WRITE_OFF_WINDOW_SECONDS} s"
    )
    env.assert_vault_reverts_with(
        "ShortfallOnFile()", 1_500_000, "Empty write-off: a deposit should wait for the recovery window",
        "wrap(uint256,bytes32,uint256)", netuid, attested_hotkey, 0,
    )

    chain.wait_for_timestamp(deadline, timeout=2 * WRITE_OFF_WINDOW_SECONDS)
    write_off_receipt = env.sync_backing(token_id, label="syncBacking [write off]")
    expected = chain.event_word(
        write_off_receipt, "BackingWrittenOff(uint256,uint256,uint256)", 0, "Empty write-off: write-off",
    )
    located = chain.event_word(
        write_off_receipt, "BackingWrittenOff(uint256,uint256,uint256)", 1, "Empty write-off: write-off",
    )
    parked_nonce = chain.event_word(
        write_off_receipt, "BackingParked(uint256,uint256,uint256)", 1, "Empty write-off: parking",
    )
    assert expected == recorded, f"the write-off expected {expected} RAO; the record held {recorded}"
    assert located == 0, f"the write-off located {located} RAO of a fully swept gift"
    assert parked_nonce == 0, f"the write-off parked an empty token at registry nonce {parked_nonce}"
    assert not env.awaiting_attestation(token_id), "an empty token must not wait for the registry owner"
    assert env.write_off_deadline(token_id) == 0, "nothing should be on file after the write-off"
    assert env.backing_intact(token_id), "the written-off record accounts for itself"

    deposit = config.DEPOSIT_RAO // 10
    wrap_receipt = env.deposit_and_wrap(
        netuid, attested_hotkey, attested_ss58, deposit, 1_500_000,
        "Empty write-off: the deposit should wrap without a registry update",
    )
    assert registry_nonce() == nonce_before, "the registry published nothing in this scenario"
    deposited = env.deposited(wrap_receipt, netuid)
    backing = env.total_stake_across(
        clone_coldkey, netuid, hotkeys, chain.receipt_block_number(wrap_receipt, "Empty write-off: wrap"),
    )
    assert abs(backing - deposited) <= config.ROUNDING_DUST_TOTAL_RAO, (
        f"the fresh position holds {backing} RAO against a deposit of {deposited}"
    )
    assert not env.awaiting_attestation(token_id), "the fresh position is ordinary"
    exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Empty write-off: the fresh position should exit cleanly",
        hotkeys=hotkeys,
    )
