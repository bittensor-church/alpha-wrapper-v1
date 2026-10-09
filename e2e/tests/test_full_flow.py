"""Deposits, every exit, emissions, rotation and observability with one configured validator per subnet."""
import re

import pytest

from alpha_e2e import chain, checks, config, exits, extrinsics
from alpha_e2e.checks import run_observability_script
from alpha_e2e.substrate import h160_to_ss58

# What a caller gives up against the lens quote when bounding a wrap.
WRAP_SLIPPAGE_TOLERANCE_PCT = 1
# Long enough for at least two epochs at tempo 10.
EMISSION_WAIT_BLOCKS = 30


@pytest.mark.scenario
def test_deposits_and_every_exit_survive_emissions_and_validator_rotation(env):
    # --- Phase 6: transfer alpha to each subnet's configured validator ---
    for subnet_index, netuid in enumerate(env.netuids):
        mailbox = env.mailbox_address(netuid)
        print(f"  netuid {netuid} mailbox: {mailbox} ({h160_to_ss58(mailbox)})")
        hotkey_pubkey = env.subnet_hotkey_pubkeys(subnet_index)[0]
        extrinsics.transfer_stake(
            h160_to_ss58(mailbox), env.hotkey_ss58s[subnet_index * config.VALIDATORS_PER_SUBNET], netuid,
            config.DEPOSIT_RAO,
        )
        mailbox_stake = env.stake(hotkey_pubkey, env.mailbox_coldkey(netuid), netuid)
        # Emissions only add, and an epoch may land before the read.
        assert mailbox_stake >= config.DEPOSIT_RAO - config.ROUNDING_DUST_SLOT_RAO, (
            f"mailbox {mailbox} holds {mailbox_stake} RAO after a {config.DEPOSIT_RAO} RAO transfer"
        )

    # --- Phase 7: process deposits (one wrap per validator) --------------------
    # The first deposit doubles as the mint slippage-guard leg: quote it on the lens,
    # show a bound above the quote is refused, then wrap under a caller's tolerance.
    wrap_receipts = []
    for subnet_index, netuid in enumerate(env.netuids):
        hotkey_pubkey = env.subnet_hotkey_pubkeys(subnet_index)[0]
        min_shares_out = 0
        if subnet_index == 0:
            deposit_alpha = env.stake(hotkey_pubkey, env.mailbox_coldkey(netuid), netuid)
            quoted_shares = env.preview_wrap(env.token_ids[subnet_index], deposit_alpha)
            checks.assert_first_deposit_shares(quoted_shares, deposit_alpha, "previewWrap on an empty position")
            env.assert_vault_reverts_with(
                "SlippageExceeded(uint256)", 1_000_000,
                "Mint guard: wrap above the previewWrap quote did NOT revert as SlippageExceeded",
                "wrap(uint256,bytes32,uint256)", netuid, hotkey_pubkey, quoted_shares * 2,
            )
            min_shares_out = quoted_shares * (100 - WRAP_SLIPPAGE_TOLERANCE_PCT) // 100
            print(f"  netuid {netuid}: previewWrap quoted {quoted_shares} shares; "
                  f"wrapping with minSharesOut={min_shares_out}")
        wrap_receipts.append(env.wrap(
            netuid, hotkey_pubkey, 1_000_000, f"wrap for netuid {netuid}, hotkey {hotkey_pubkey[:18]}... failed",
            min_shares_out=min_shares_out,
        ))

    # --- Phase 8: verify deposits ----------------------------------------------
    for subnet_index, netuid in enumerate(env.netuids):
        token_id = env.token_ids[subnet_index]
        hotkeys = env.subnet_hotkey_pubkeys(subnet_index)
        receipt = wrap_receipts[subnet_index]
        deposited = env.deposited(receipt, netuid, hotkeys[0])
        shares = env.vault_shares(token_id)
        print(f"  netuid {netuid} (tokenId {token_id}): deposited {deposited} RAO, shares={shares}")
        checks.assert_first_deposit_shares(shares, deposited, f"netuid {netuid}")
        wrap_block = chain.receipt_block_number(receipt, "wrap")
        landed = env.stake_change(env.clone_coldkey(token_id), netuid, hotkeys, wrap_block)
        assert abs(landed - deposited) <= config.ROUNDING_DUST_SLOT_RAO, (
            f"netuid {netuid}: the clone gained {landed} RAO from a {deposited} RAO deposit"
        )

    # --- Phase 9: unwrap all shares -> the alpha comes back -----------------------
    for subnet_index, netuid in enumerate(env.netuids):
        token_id = env.token_ids[subnet_index]
        hotkeys = env.subnet_hotkey_pubkeys(subnet_index)
        receipt, received = exits.unwrap(
            env, token_id, env.vault_shares(token_id), f"unwrap for netuid {netuid} failed", hotkeys=hotkeys,
        )
        assert env.vault_shares(token_id) == 0, f"netuid {netuid}: shares left after a full unwrap"
        exits.assert_drained(env, token_id, hotkeys, receipt, f"netuid {netuid}: full unwrap")
        print(f"  netuid {netuid}: received {received} RAO")

    # --- Phase 10: observability scripts -----------------------------------------
    block_end = chain.cast_block_number()
    print(f"  Block range: [{env.observation_block_start}, {block_end}]")

    subnet_count = len(env.netuids)
    token_id_set = {str(token_id) for token_id in env.token_ids}
    vault_args = ["--vault-address", env.vault_address]

    checks.assert_csv(
        run_observability_script(
            "get_subnet_proxies",
            block_start=env.observation_block_start, block_end=block_end,
            address_args=vault_args,
        ),
        rows=subnet_count,
        column_sets={"token_id": token_id_set},
    )

    checks.assert_csv(
        run_observability_script(
            "get_deposits",
            block_start=env.observation_block_start, block_end=block_end,
            address_args=vault_args,
        ),
        rows=subnet_count,
        column_sets={"token_id": token_id_set},
        column_eq={"user": config.WRAPPER_USER_ADDRESS},
        column_positive=["assets", "shares"],
    )

    checks.assert_csv(
        run_observability_script(
            "get_unwraps",
            block_start=env.observation_block_start, block_end=block_end,
            address_args=vault_args,
        ),
        rows=subnet_count,
        column_sets={"token_id": token_id_set},
        column_eq={"user": config.WRAPPER_USER_ADDRESS},
        column_positive=["alpha_out_rao", "shares"],
    )

    # Per netuid: 0 or 1 emission depending on whether the post-drain leftover
    # (emissions accrued between deposit and unwrap) clears the vault's tao stake
    # floor. Assert membership only.
    checks.assert_csv(
        run_observability_script(
            "get_rebalances",
            block_start=env.observation_block_start, block_end=block_end,
            address_args=vault_args,
        ),
        column_subsets={"token_id": token_id_set},
        column_positive=["amount"],
    )

    checks.assert_csv(
        run_observability_script(
            "get_validator_updates",
            block_start=env.registry_block_start, block_end=env.registry_block_end,
            address_args=["--registry-address", env.validator_registry_address],
        ),
        rows=subnet_count,
        column_sets={"netuid": {str(netuid) for netuid in env.netuids}},
        column_eq={"count": "1"},
        column_positive=["timestamp"],
    )

    for subnet_index, netuid in enumerate(env.netuids):
        token_id = env.token_ids[subnet_index]

        checks.assert_csv(
            run_observability_script(
                "get_volumes", "--netuid", str(netuid),
                block_start=env.observation_block_start, block_end=block_end,
                address_args=vault_args,
            ),
            rows=1,
            column_eq={
                "token_id": str(token_id),
                "user": "",
                "deposit_count": "1",
                "alpha_unwrap_count": "1",
                "tao_unwrap_count": "0",
                "dissolved_unwrap_count": "0",
                "unwrap_count": "1",
                "tao_received_wei": "0",
            },
            column_positive=[
                "alpha_deposited_rao", "shares_minted", "alpha_unwrapped_rao", "shares_burned",
            ],
        )

        checks.assert_csv(
            run_observability_script(
                "get_volumes", "--netuid", str(netuid), "--user", config.WRAPPER_USER_ADDRESS,
                block_start=env.observation_block_start, block_end=block_end,
                address_args=vault_args,
            ),
            rows=1,
            column_eq={
                "token_id": str(token_id),
                "user": config.WRAPPER_USER_ADDRESS,
                "deposit_count": "1",
                "alpha_unwrap_count": "1",
                "tao_unwrap_count": "0",
                "dissolved_unwrap_count": "0",
                "unwrap_count": "1",
            },
        )

        vault_state_csv = run_observability_script(
            "get_vault_state", "--netuid", str(netuid),
            address_args=[
                "--vault-address", env.vault_address,
                "--lens-address", env.lens_address,
                "--registry-address", env.validator_registry_address,
            ],
        )
        checks.assert_csv(
            vault_state_csv,
            rows=1,
            column_eq={
                "token_id": str(token_id),
                "total_supply": "0",
                "share_price": "",
                "share_price_error": "NoSharesOutstanding",
                "validators_count": "1",
            },
        )

    # --- Phase 11: reclaim mailbox alpha as TAO ------------------------------------
    reclaim_netuid = env.netuids[0]
    reclaim_hotkey_pubkey = env.hotkey_pubkeys[0]
    reclaim_hotkey_ss58 = env.hotkey_ss58s[0]

    extrinsics.transfer_stake(
        h160_to_ss58(env.mailbox_address(reclaim_netuid)), reclaim_hotkey_ss58, reclaim_netuid, config.DEPOSIT_RAO,
    )
    exits.reclaim_mailbox_alpha_as_tao(env, reclaim_netuid, reclaim_hotkey_pubkey, "mailbox sale")

    # --- Phase 12: reclaim mailbox alpha back to the user's own coldkey --------------
    extrinsics.transfer_stake(
        h160_to_ss58(env.mailbox_address(reclaim_netuid)), reclaim_hotkey_ss58, reclaim_netuid, config.DEPOSIT_RAO,
    )
    mailbox_coldkey = env.mailbox_coldkey(reclaim_netuid)
    reclaim_receipt = env.vault_send_between_epochs(
        reclaim_netuid, 1_500_000, "reclaimAlphaFromMailbox failed",
        "reclaimAlphaFromMailbox(uint256,bytes32,bytes32)",
        reclaim_netuid, reclaim_hotkey_pubkey, env.wrapper_substrate_coldkey,
    )
    reclaim_block = chain.receipt_block_number(reclaim_receipt, "reclaimAlphaFromMailbox")
    released = -env.stake_change(mailbox_coldkey, reclaim_netuid, [reclaim_hotkey_pubkey], reclaim_block)
    returned = env.stake_change(env.wrapper_substrate_coldkey, reclaim_netuid, [reclaim_hotkey_pubkey], reclaim_block)
    assert released >= config.DEPOSIT_RAO - config.ROUNDING_DUST_SLOT_RAO, (
        f"the mailbox released {released} RAO of a {config.DEPOSIT_RAO} RAO deposit"
    )
    assert abs(returned - released) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the user got back {returned} RAO of the {released} RAO the mailbox released"
    )
    leftover = env.stake(reclaim_hotkey_pubkey, mailbox_coldkey, reclaim_netuid, reclaim_block)
    assert leftover <= config.ROUNDING_DUST_SLOT_RAO, f"the mailbox still holds {leftover} RAO after the reclaim"

    # --- Phase 13: planned TAO exit (scripts/plan_tao_exit.py + the masked unwrapForTao) --
    tao_exit_netuid = env.netuids[1]
    tao_exit_token_id = env.token_ids[1]
    tao_exit_hotkeys = env.subnet_hotkey_pubkeys(1)
    tao_exit_block_start = chain.cast_block_number()

    env.deposit_and_wrap(
        tao_exit_netuid, tao_exit_hotkeys[0], env.hotkey_ss58s[3],
        config.DEPOSIT_RAO, 1_500_000, "wrap for unwrapForTao setup failed",
    )
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
    tao_receipt, _ = exits.unwrap_for_tao(
        env, tao_exit_token_id, tao_exit_shares, "full TAO exit", hotkeys=tao_exit_hotkeys,
        excluded_slots=int(planned_mask.group(1)),
    )
    assert env.vault_shares(tao_exit_token_id) == 0, "shares left after a full unwrapForTao"
    exits.assert_drained(env, tao_exit_token_id, tao_exit_hotkeys, tao_receipt, "full TAO exit")

    tao_exit_block_end = chain.cast_block_number()
    checks.assert_csv(
        run_observability_script(
            "get_volumes", "--token-id", str(tao_exit_token_id),
            "--user", config.WRAPPER_USER_ADDRESS,
            block_start=tao_exit_block_start, block_end=tao_exit_block_end,
            address_args=vault_args,
        ),
        rows=1,
        column_eq={
            "token_id": str(tao_exit_token_id),
            "user": config.WRAPPER_USER_ADDRESS,
            "deposit_count": "1",
            "alpha_unwrap_count": "0",
            "tao_unwrap_count": "1",
            "dissolved_unwrap_count": "0",
            "unwrap_count": "1",
            "tao_from_dissolutions_wei": "0",
        },
        column_positive=[
            "alpha_sold_for_tao_rao", "tao_from_alpha_sales_wei", "tao_received_wei",
        ],
    )

    # --- Phase 14: emission accrual -> the holder unwraps the gain (alpha rail) ------
    emission_netuid = env.netuids[0]
    emission_token_id = env.token_ids[0]
    emission_hotkeys = env.subnet_hotkey_pubkeys(0)
    emission_clone = env.clone_coldkey(emission_token_id)

    receipt = env.deposit_and_wrap(
        emission_netuid, emission_hotkeys[0], env.hotkey_ss58s[0],
        50 * config.RAO_PER_ALPHA, 1_500_000, "Phase 14 wrap failed",
    )
    emission_deposited = env.deposited(receipt, emission_netuid, emission_hotkeys[0])
    backing_at_wrap = env.total_stake_across(
        emission_clone, emission_netuid, emission_hotkeys, chain.receipt_block_number(receipt, "Phase 14 wrap"),
    )
    print(f"  Deposited {emission_deposited} RAO; waiting {EMISSION_WAIT_BLOCKS} blocks for emissions...")
    chain.wait_for_blocks(EMISSION_WAIT_BLOCKS, timeout=EMISSION_WAIT_BLOCKS * config.BLOCK_TIMEOUT_SECONDS)
    backing_now = env.total_stake_across(emission_clone, emission_netuid, emission_hotkeys)
    assert backing_now > backing_at_wrap, (
        f"Phase 14: no emissions reached the clone ({backing_at_wrap} -> {backing_now} RAO)"
    )

    _, emission_received = exits.unwrap(
        env, emission_token_id, env.vault_shares(emission_token_id), "Phase 14 unwrap failed",
        hotkeys=emission_hotkeys,
    )
    assert emission_received > emission_deposited, (
        f"Phase 14: emissions not captured (received {emission_received} <= deposit {emission_deposited})"
    )
    print(f"  User unwrapped {emission_received} RAO > deposited {emission_deposited}")

    # --- Phase 15: rotation leaves rotated-out stake -> unwrap consolidates it -------
    rotation_netuid = env.netuids[1]
    rotation_token_id = env.token_ids[1]
    rotation_hotkeys = env.subnet_hotkey_pubkeys(1)
    rotated_out_hotkey, new_target = rotation_hotkeys[:2]

    receipt = env.deposit_and_wrap(
        rotation_netuid, rotated_out_hotkey, env.hotkey_ss58s[3],
        60 * config.RAO_PER_ALPHA, 1_500_000, "Phase 15 wrap failed",
    )
    rotation_deposited = env.deposited(receipt, rotation_netuid, rotated_out_hotkey)
    rotation_clone_coldkey = env.clone_coldkey(rotation_token_id)
    rotated_out_stake = env.stake(rotated_out_hotkey, rotation_clone_coldkey, rotation_netuid)
    assert rotated_out_stake != 0, "Phase 15: no stake under the validator to rotate out"

    # Registry updates leave stake in place until a vault call moves it.
    env.set_validator(rotation_netuid, new_target)

    _, rotation_received = exits.unwrap(
        env, rotation_token_id, env.vault_shares(rotation_token_id), "Phase 15 unwrap failed",
        hotkeys=rotation_hotkeys, tolerance=config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO,
    )
    assert rotation_received >= rotation_deposited - config.CONSOLIDATION_ROUNDING_TOLERANCE_RAO, (
        f"Phase 15: received {rotation_received} RAO of a {rotation_deposited} RAO deposit"
    )
    rotated_out_stake_after = env.stake(rotated_out_hotkey, rotation_clone_coldkey, rotation_netuid)
    assert rotated_out_stake_after <= config.ROUNDING_DUST_SLOT_RAO, (
        f"Phase 15: the rotated-out validator still holds {rotated_out_stake_after} RAO"
    )

    # --- Phase 16: unwrapForTao slippage guard against the real alpha->TAO price -----
    slippage_netuid = env.netuids[2]
    slippage_token_id = env.token_ids[2]
    slippage_hotkeys = env.subnet_hotkey_pubkeys(2)

    env.deposit_and_wrap(
        slippage_netuid, slippage_hotkeys[0], env.hotkey_ss58s[6],
        40 * config.RAO_PER_ALPHA, 1_500_000, "Phase 16 wrap failed",
    )
    slippage_shares = env.vault_shares(slippage_token_id)
    position_alpha = env.total_stake_across(env.clone_coldkey(slippage_token_id), slippage_netuid, slippage_hotkeys)
    unreachable_tao_out = 2 * env.alpha_to_tao_quote(slippage_netuid, position_alpha) * config.WEI_PER_RAO
    env.assert_vault_reverts_with(
        "SlippageExceeded(uint256)", 2_500_000,
        "Phase 16: unwrapForTao asking twice the pool's quote did NOT revert as SlippageExceeded",
        "unwrapForTao(uint256,uint256,uint256)", slippage_token_id, slippage_shares, unreachable_tao_out,
    )

    receipt, _ = exits.unwrap_for_tao(
        env, slippage_token_id, slippage_shares, "Phase 16 unwrapForTao(minTaoOut=0)", hotkeys=slippage_hotkeys,
    )
    assert env.vault_shares(slippage_token_id) == 0, "Phase 16: shares not burned"
    exits.assert_drained(env, slippage_token_id, slippage_hotkeys, receipt, "Phase 16")
