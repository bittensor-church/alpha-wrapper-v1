"""Deposits, every exit, emissions, rotation and observability with one configured validator per subnet.

Each subnet takes a first deposit, previewed and slippage-guarded on the first, and exits it in
alpha; every observability script then reports exactly those deposits, exits and registry
updates. The first subnet's mailbox is reclaimed both ways, the second subnet exits in TAO
through a planned mask, a position held across epochs exits with its emissions, a position on
a rotated-out validator exits through consolidation, and a TAO exit asking twice the pool's
quote is refused.
"""
import re

import pytest

from alpha_e2e import chain, checks, config, exits, extrinsics
from alpha_e2e.checks import assert_csv_rows, run_observability_script, volume_row
from alpha_e2e.substrate import h160_to_ss58

WRAP_SLIPPAGE_TOLERANCE_PCT = 1


@pytest.mark.scenario
def test_deposits_and_every_exit_survive_emissions_and_validator_rotation(env):
    for subnet_index, netuid in enumerate(env.netuids):
        mailbox = env.mailbox_address(netuid)
        print(f"  netuid {netuid} mailbox: {mailbox} ({h160_to_ss58(mailbox)})")
        env.send_to_mailbox(netuid, env.subnet_hotkey_ss58s(subnet_index)[0], config.DEPOSIT_RAO)
        mailbox_stake = env.mailbox_deposit(netuid)
        assert config.DEPOSIT_RAO - config.ROUNDING_DUST_SLOT_RAO <= mailbox_stake <= config.DEPOSIT_RAO, (
            f"mailbox {mailbox} holds {mailbox_stake} RAO after a {config.DEPOSIT_RAO} RAO transfer"
        )

    wrap_receipts = []
    for subnet_index, netuid in enumerate(env.netuids):
        hotkey_pubkey = env.subnet_hotkey_pubkeys(subnet_index)[0]
        min_shares_out = 0
        if subnet_index == 0:
            deposit_alpha = env.mailbox_deposit(netuid)
            quoted_shares = env.preview_wrap(env.token_ids[subnet_index], deposit_alpha)
            checks.assert_first_deposit_shares(quoted_shares, deposit_alpha, "previewWrap on an empty position")
            env.assert_vault_reverts_with(
                "SlippageExceeded(uint256)", 1_500_000,
                "Mint guard: a wrap asking twice its first-deposit shares should revert as SlippageExceeded",
                "wrap(uint256,bytes32,uint256)", netuid, hotkey_pubkey, quoted_shares * 2,
                error_args=(deposit_alpha * config.SHARES_PER_RAO_AT_FIRST_DEPOSIT,),
            )
            min_shares_out = quoted_shares * (100 - WRAP_SLIPPAGE_TOLERANCE_PCT) // 100
            print(f"  netuid {netuid}: previewWrap quoted {quoted_shares} shares; "
                  f"wrapping with minSharesOut={min_shares_out}")
        wrap_receipts.append(env.wrap(
            netuid, hotkey_pubkey, 1_000_000, f"wrap for netuid {netuid}, hotkey {hotkey_pubkey[:18]}... failed",
            min_shares_out=min_shares_out,
        ))

    deposits = {}
    for subnet_index, netuid in enumerate(env.netuids):
        token_id = env.token_ids[subnet_index]
        hotkeys = env.subnet_hotkey_pubkeys(subnet_index)
        receipt = wrap_receipts[subnet_index]
        deposited = env.deposited(receipt, netuid)
        shares = env.vault_shares(token_id)
        print(f"  netuid {netuid} (tokenId {token_id}): deposited {deposited} RAO, shares={shares}")
        checks.assert_first_deposit_shares(shares, deposited, f"netuid {netuid}")
        wrap_block = chain.receipt_block_number(receipt, "wrap")
        landed = env.stake_change(env.clone_coldkey(token_id), netuid, hotkeys, wrap_block)
        assert abs(landed - deposited) <= config.ROUNDING_DUST_SLOT_RAO, (
            f"netuid {netuid}: the clone gained {landed} RAO from a {deposited} RAO deposit"
        )
        deposits[token_id] = (deposited, shares)

    received_by_token = {}
    for subnet_index, netuid in enumerate(env.netuids):
        token_id = env.token_ids[subnet_index]
        hotkeys = env.subnet_hotkey_pubkeys(subnet_index)
        receipt, received = exits.unwrap(
            env, token_id, env.vault_shares(token_id), f"unwrap for netuid {netuid} failed", hotkeys=hotkeys,
        )
        assert env.vault_shares(token_id) == 0, f"netuid {netuid}: shares left after a full unwrap"
        exits.assert_drained(env, token_id, hotkeys, receipt, f"netuid {netuid}: full unwrap")
        received_by_token[token_id] = received
        print(f"  netuid {netuid}: received {received} RAO")

    block_end = chain.cast_block_number()
    print(f"  Block range: [{env.observation_block_start}, {block_end}]")
    vault_args = ["--vault-address", env.vault_address]
    user = config.WRAPPER_USER_ADDRESS

    def event_report(script: str) -> str:
        return run_observability_script(
            script, block_start=env.observation_block_start, block_end=block_end, address_args=vault_args,
        )

    assert_csv_rows(
        event_report("get_subnet_proxies"),
        [{"token_id": token_id, "clone": env.clone_address(token_id)} for token_id in env.token_ids],
        "get_subnet_proxies",
    )
    assert_csv_rows(
        event_report("get_deposits"),
        [
            {"user": user, "token_id": token_id, "assets": deposited, "shares": shares}
            for token_id, (deposited, shares) in deposits.items()
        ],
        "get_deposits",
    )
    assert_csv_rows(
        event_report("get_unwraps"),
        [
            {"user": user, "token_id": token_id, "shares": deposits[token_id][1], "alpha_out_rao": received}
            for token_id, received in received_by_token.items()
        ],
        "get_unwraps",
    )
    assert_csv_rows(event_report("get_rebalances"), [], "get_rebalances: a one-validator set never realigns weights")
    assert_csv_rows(
        run_observability_script(
            "get_validator_updates",
            block_start=env.registry_block_start, block_end=env.registry_block_end,
            address_args=["--registry-address", env.validator_registry_address],
        ),
        [
            {
                "tx_hash": receipt["transactionHash"], "netuid": netuid, "nonce": 1, "count": 1,
                "timestamp": chain.block_timestamp(chain.receipt_block_number(receipt, "setValidator")),
            }
            for netuid, receipt in zip(env.netuids, env.registry_update_receipts)
        ],
        "get_validator_updates",
    )

    for subnet_index, netuid in enumerate(env.netuids):
        token_id = env.token_ids[subnet_index]
        deposited, shares = deposits[token_id]
        alpha_volumes = {
            "deposit_count": 1, "alpha_deposited_rao": deposited, "shares_minted": shares,
            "alpha_unwrap_count": 1, "alpha_unwrap_shares_burned": shares,
            "alpha_unwrapped_rao": received_by_token[token_id], "unwrap_count": 1, "shares_burned": shares,
        }
        assert_csv_rows(
            run_observability_script(
                "get_volumes", "--netuid", str(netuid),
                block_start=env.observation_block_start, block_end=block_end, address_args=vault_args,
            ),
            [volume_row(token_id, "", **alpha_volumes)],
            f"get_volumes for netuid {netuid}",
        )
        assert_csv_rows(
            run_observability_script(
                "get_volumes", "--netuid", str(netuid), "--user", user,
                block_start=env.observation_block_start, block_end=block_end, address_args=vault_args,
            ),
            [volume_row(token_id, user, **alpha_volumes)],
            f"get_volumes for netuid {netuid} and the wrapper user",
        )

        hotkeys = env.subnet_hotkey_pubkeys(subnet_index)
        state = run_observability_script(
            "get_vault_state", "--netuid", str(netuid),
            address_args=[
                "--vault-address", env.vault_address,
                "--lens-address", env.lens_address,
                "--registry-address", env.validator_registry_address,
            ],
        )
        state_block = int(checks.csv_rows(state)[0]["block"])
        assert_csv_rows(
            state,
            [{
                "block": state_block, "token_id": token_id, "total_supply": 0,
                "total_stake": env.total_stake_across(env.clone_coldkey(token_id), netuid, hotkeys, state_block),
                "total_stake_error": "", "write_off_deadline": 0, "awaiting_attestation": False,
                "share_price": "", "share_price_error": "NoSharesOutstanding",
                "subnet_clone": env.clone_address(token_id), "validators_count": 1,
                "validator_1_hotkey": hotkeys[0], "validator_1_weight": 10_000,
            }],
            f"get_vault_state for netuid {netuid}",
        )

    reclaim_netuid = env.netuids[0]
    reclaim_hotkey_ss58 = env.subnet_hotkey_ss58s(0)[0]
    mailbox_coldkey = env.mailbox_coldkey(reclaim_netuid)

    env.send_to_mailbox(reclaim_netuid, reclaim_hotkey_ss58, config.DEPOSIT_RAO)
    exits.reclaim_mailbox_alpha_as_tao(env, reclaim_netuid, "mailbox sale")

    env.send_to_mailbox(reclaim_netuid, reclaim_hotkey_ss58, config.DEPOSIT_RAO)
    reclaim_receipt = env.vault_send_between_epochs(
        reclaim_netuid, 1_500_000, "reclaimAlphaFromMailbox failed",
        "reclaimAlphaFromMailbox(uint256,bytes32)",
        reclaim_netuid, env.wrapper_substrate_coldkey,
    )
    reclaim_block = chain.receipt_block_number(reclaim_receipt, "reclaimAlphaFromMailbox")
    released = -env.stake_change(mailbox_coldkey, reclaim_netuid, [mailbox_coldkey], reclaim_block)
    returned = env.stake_change(env.wrapper_substrate_coldkey, reclaim_netuid, [mailbox_coldkey], reclaim_block)
    assert config.DEPOSIT_RAO - config.ROUNDING_DUST_SLOT_RAO <= released <= config.DEPOSIT_RAO, (
        f"the mailbox released {released} RAO of a {config.DEPOSIT_RAO} RAO deposit"
    )
    assert abs(returned - released) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the user got back {returned} RAO of the {released} RAO the mailbox released"
    )
    leftover = env.stake(mailbox_coldkey, mailbox_coldkey, reclaim_netuid, reclaim_block)
    assert leftover <= config.ROUNDING_DUST_SLOT_RAO, f"the mailbox still holds {leftover} RAO after the reclaim"

    tao_exit_netuid = env.netuids[1]
    tao_exit_token_id = env.token_ids[1]
    tao_exit_hotkeys = env.subnet_hotkey_pubkeys(1)
    tao_exit_block_start = chain.cast_block_number()

    tao_exit_wrap = env.deposit_and_wrap(
        tao_exit_netuid, tao_exit_hotkeys[0], env.subnet_hotkey_ss58s(1)[0],
        config.DEPOSIT_RAO, 1_500_000, "wrap for unwrapForTao setup failed",
    )
    tao_exit_deposited = env.deposited(tao_exit_wrap, tao_exit_netuid)
    tao_exit_shares = env.vault_shares(tao_exit_token_id)
    plan = run_observability_script(
        "plan_tao_exit", "--token-id", str(tao_exit_token_id),
        "--holder", config.WRAPPER_USER_ADDRESS, "--shares", str(tao_exit_shares),
        address_args=["--vault-address", env.vault_address, "--lens-address", env.lens_address],
    )
    print(plan)
    planned_mask = re.search(r"excludedSlots mask: (\d+)", plan)
    assert planned_mask is not None, f"the planner printed no mask:\n{plan}"
    assert int(planned_mask.group(1)) == 0, f"the pool should pay for the only slot:\n{plan}"
    assert "sellable" in plan, f"the planner should call the slot sellable:\n{plan}"
    env.assert_vault_reverts_with(
        "SlotMaskOutOfRange()", 1_000_000,
        "a mask naming a slot past the record should be refused",
        "unwrapForTao(uint256,uint256,uint256,uint256)", tao_exit_token_id, tao_exit_shares, 0, 0b10,
    )
    tao_receipt, tao_exit_sold = exits.unwrap_for_tao(
        env, tao_exit_token_id, tao_exit_shares, "full TAO exit", hotkeys=tao_exit_hotkeys,
        excluded_slots=int(planned_mask.group(1)),
    )
    assert env.vault_shares(tao_exit_token_id) == 0, "shares left after a full unwrapForTao"
    exits.assert_drained(env, tao_exit_token_id, tao_exit_hotkeys, tao_receipt, "full TAO exit")
    tao_exit = checks.tao_exit_report(tao_receipt, "full TAO exit")

    tao_exit_block_end = chain.cast_block_number()
    assert_csv_rows(
        run_observability_script(
            "get_volumes", "--token-id", str(tao_exit_token_id), "--user", user,
            block_start=tao_exit_block_start, block_end=tao_exit_block_end, address_args=vault_args,
        ),
        [volume_row(
            tao_exit_token_id, user,
            deposit_count=1, alpha_deposited_rao=tao_exit_deposited, shares_minted=tao_exit_shares,
            tao_unwrap_count=1, tao_unwrap_shares_burned=tao_exit_shares,
            tao_unwrap_shares_refunded=tao_exit.shares_refunded, alpha_sold_for_tao_rao=tao_exit_sold,
            tao_from_alpha_sales_wei=tao_exit.tao_out_wei, unwrap_count=1,
            shares_burned=tao_exit_shares, tao_received_wei=tao_exit.tao_out_wei,
        )],
        "get_volumes for the TAO exit",
    )

    emission_netuid = env.netuids[0]
    emission_token_id = env.token_ids[0]
    emission_hotkeys = env.subnet_hotkey_pubkeys(0)
    emission_clone = env.clone_coldkey(emission_token_id)

    receipt = env.deposit_and_wrap(
        emission_netuid, emission_hotkeys[0], env.subnet_hotkey_ss58s(0)[0],
        50 * config.RAO_PER_ALPHA, 1_500_000, "Emissions: wrap failed",
    )
    emission_deposited = env.deposited(receipt, emission_netuid)
    backing_at_wrap = env.total_stake_across(
        emission_clone, emission_netuid, emission_hotkeys, chain.receipt_block_number(receipt, "Emissions: wrap"),
    )
    _, tempo, _ = extrinsics.epoch_schedule(emission_netuid)
    print(f"  Deposited {emission_deposited} RAO; waiting for an epoch's emission...")
    env.wait_for_stake_above(
        backing_at_wrap, emission_clone, emission_netuid, emission_hotkeys,
        timeout=2 * (tempo + 2) * config.BLOCK_TIMEOUT_SECONDS,
    )

    _, emission_received = exits.unwrap(
        env, emission_token_id, env.vault_shares(emission_token_id), "Emissions: unwrap failed",
        hotkeys=emission_hotkeys,
    )
    assert emission_received > emission_deposited, (
        f"Emissions: not captured (received {emission_received} <= deposit {emission_deposited})"
    )
    print(f"  User unwrapped {emission_received} RAO > deposited {emission_deposited}")

    rotation_netuid = env.netuids[1]
    rotation_token_id = env.token_ids[1]
    rotation_hotkeys = env.subnet_hotkey_pubkeys(1)
    rotated_out_hotkey, new_target = rotation_hotkeys[:2]

    receipt = env.deposit_and_wrap(
        rotation_netuid, rotated_out_hotkey, env.subnet_hotkey_ss58s(1)[0],
        60 * config.RAO_PER_ALPHA, 1_500_000, "Rotation: wrap failed",
    )
    rotation_deposited = env.deposited(receipt, rotation_netuid)
    rotation_clone_coldkey = env.clone_coldkey(rotation_token_id)
    rotated_out_stake = env.stake(rotated_out_hotkey, rotation_clone_coldkey, rotation_netuid)
    assert rotated_out_stake != 0, "Rotation: no stake under the validator to rotate out"

    env.set_validator(rotation_netuid, new_target)

    _, rotation_received = exits.unwrap(
        env, rotation_token_id, env.vault_shares(rotation_token_id), "Rotation: unwrap failed",
        hotkeys=rotation_hotkeys, tolerance=config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
    )
    assert rotation_received >= rotation_deposited - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        f"Rotation: received {rotation_received} RAO of a {rotation_deposited} RAO deposit"
    )
    rotated_out_stake_after = env.stake(rotated_out_hotkey, rotation_clone_coldkey, rotation_netuid)
    assert rotated_out_stake_after <= config.ROUNDING_DUST_SLOT_RAO, (
        f"Rotation: the rotated-out validator still holds {rotated_out_stake_after} RAO"
    )

    slippage_netuid = env.netuids[2]
    slippage_token_id = env.token_ids[2]
    slippage_hotkeys = env.subnet_hotkey_pubkeys(2)

    env.deposit_and_wrap(
        slippage_netuid, slippage_hotkeys[0], env.subnet_hotkey_ss58s(2)[0],
        40 * config.RAO_PER_ALPHA, 1_500_000, "TAO slippage: wrap failed",
    )
    slippage_shares = env.vault_shares(slippage_token_id)
    position_alpha = env.total_stake_across(env.clone_coldkey(slippage_token_id), slippage_netuid, slippage_hotkeys)
    unreachable_tao_out = 2 * env.alpha_to_tao_quote(slippage_netuid, position_alpha) * config.WEI_PER_RAO
    env.assert_vault_reverts_with(
        "SlippageExceeded(uint256)", 2_500_000,
        "TAO slippage: unwrapForTao asking twice the pool's quote should revert as SlippageExceeded",
        "unwrapForTao(uint256,uint256,uint256)", slippage_token_id, slippage_shares, unreachable_tao_out,
    )

    receipt, _ = exits.unwrap_for_tao(
        env, slippage_token_id, slippage_shares, "TAO slippage: unwrapForTao(minTaoOut=0)", hotkeys=slippage_hotkeys,
    )
    assert env.vault_shares(slippage_token_id) == 0, "TAO slippage: shares not burned"
    exits.assert_drained(env, slippage_token_id, slippage_hotkeys, receipt, "TAO slippage")
