"""A token follows the chain's registration counter, not the registration block.

Chain migrations have rewritten live subnets' registration blocks. A position must
survive that untouched, while a subnet dissolved and registered again must get a new
token with the old one still redeemable for its dissolution refund.
"""
import pytest

from alpha_e2e import bootstrap, chain, checks, config, exits, extrinsics

IMMUNITY_EXTENSION_BLOCKS = 13 * 7200


@pytest.mark.scenario
def test_token_follows_the_registration_counter_not_the_block(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)

    env.deposit_and_wrap(
        netuid, hotkeys[0], env.hotkey_ss58s[0],
        config.DEPOSIT_RAO, 1_500_000, "Generation: wrap failed",
    )
    shares = env.vault_shares(token_id)
    assert shares != 0, "no shares minted by the setup wrap"
    registrations = env.registration_counter(netuid)
    assert token_id == netuid | (registrations << config.NETUID_BITS), "the token id carries the registration counter"

    block_before = extrinsics.network_registration_block(netuid)
    extrinsics.set_network_registration_block(netuid, block_before + IMMUNITY_EXTENSION_BLOCKS)

    assert env.current_token_id(netuid) == token_id, "a rewritten registration block changes nothing"
    assert env.backing_intact(token_id), "the record is untouched"
    exits.unwrap(
        env, token_id, shares // 4, "Generation: the exit should pay in alpha after the rewrite",
        hotkeys=hotkeys, label="unwrap [after block rewrite]",
    )
    receipt = env.deposit_and_wrap(
        netuid, hotkeys[0], env.hotkey_ss58s[0],
        config.DEPOSIT_RAO // 10, 1_500_000, "Generation: deposits should land on the same token",
    )
    deposited = env.deposited(receipt, netuid, hotkeys[0])
    joined = env.stake_change(
        env.clone_coldkey(token_id), netuid, hotkeys, chain.receipt_block_number(receipt, "Generation: deposit"),
    )
    assert abs(joined - deposited) <= config.ROUNDING_DUST_SLOT_RAO, (
        f"the existing position's clone gained {joined} RAO of a {deposited} RAO deposit"
    )

    extrinsics.dissolve_network(netuid)
    env.wait_for_dissolution_cleanup(netuid)
    assert bootstrap.create_subnet() == netuid, "the chain hands the freed netuid back"

    assert env.registration_counter(netuid) == registrations + 1, "the counter stepped with the registration"
    assert env.current_token_id(netuid) == netuid | ((registrations + 1) << config.NETUID_BITS), "so the new subnet has a new token"

    # The sole holder's slice of the refund is all of it, floored to whole RAO.
    old_clone = env.clone_address(token_id)
    expected_refund = chain.cast_balance_wei(old_clone) // config.WEI_PER_RAO * config.WEI_PER_RAO
    assert expected_refund > 0, "the old token's clone received no dissolution refund"
    balance_before = env.user_tao_wei()
    receipt = env.vault_send(
        2_000_000, "Generation: the old token should redeem its dissolution refund",
        "unwrap(uint256,uint256,bytes32,uint256)",
        token_id, env.vault_shares(token_id), env.wrapper_substrate_coldkey, 0,
    )
    refund = checks.reconstructed_payout(balance_before, env.user_tao_wei(), receipt, "Generation: refund")
    assert refund == expected_refund, f"the old token paid {refund} wei of its clone's {expected_refund} wei refund"
    assert env.vault_total_supply(token_id) == 0, "the old token kept outstanding shares"
