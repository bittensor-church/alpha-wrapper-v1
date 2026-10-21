"""Scenario: backing on hotkey 0x0 is reachable.

Subtensor keeps an owner record for the all-zero hotkey, so a hotkey swap can carry the
vault's backing there and stake moves off it like off any other hotkey. The vault must not
read that key as "no key": after a validator swaps its hotkey onto hotkey 0x0, exits keep
paying from it. A gift onto hotkey 0x0 under the clone is refused, because the clone neither owns
nor lists that hotkey, and a wrap may not name it.
"""
import pytest

from alpha_e2e import config, exits, extrinsics
from alpha_e2e.extrinsics import UNOWNED_ACCOUNT as ZERO_HOTKEY_SS58
from alpha_e2e.substrate import h160_to_ss58

ZERO_HOTKEY = "0x" + "00" * 32
STAKE_TAO_RAO = 2 * config.RAO_PER_TAO


@pytest.mark.scenario
def test_backing_on_hotkey_zero_is_reachable(env):
    netuid = env.netuids[0]
    token_id = env.token_ids[0]
    hotkeys = env.subnet_hotkey_pubkeys(0)
    attested_hotkey, attested_ss58 = hotkeys[0], env.hotkey_ss58s[0]
    clone_coldkey = env.clone_coldkey(token_id)

    env.deposit_and_wrap(
        netuid, attested_hotkey, attested_ss58, config.DEPOSIT_RAO, 1_500_000, "Zero hotkey: wrap failed",
    )
    shares = env.vault_shares(token_id)
    backing_before = env.total_stake_across(clone_coldkey, netuid, hotkeys)

    extrinsics.associate_hotkey(ZERO_HOTKEY_SS58)
    extrinsics.add_stake(ZERO_HOTKEY_SS58, netuid, STAKE_TAO_RAO)
    gift = env.stake(ZERO_HOTKEY, config.ALICE_COLDKEY_PUBKEY, netuid)
    assert gift > 0, "Alice holds no alpha on hotkey 0 after staking to it"
    with pytest.raises(extrinsics.ExtrinsicError) as refused:
        extrinsics.transfer_stake(h160_to_ss58(env.clone_address(token_id)), ZERO_HOTKEY_SS58, netuid, gift)
    assert "AccountRejectsStakingHotkeyGrowth" in str(refused.value), str(refused.value)
    assert env.stake(ZERO_HOTKEY, clone_coldkey, netuid) == 0, "the refused gift reached the clone"

    carried = env.stake(attested_hotkey, clone_coldkey, netuid)
    extrinsics.swap_hotkey_on_subnet(attested_ss58, ZERO_HOTKEY_SS58, netuid)
    assert env.stake(ZERO_HOTKEY, clone_coldkey, netuid) >= carried - config.ROUNDING_DUST_SLOT_RAO, (
        "the swap did not carry the backing onto hotkey 0"
    )
    assert env.backing_intact(token_id), "a followed swap is not a loss"
    assert env.vault_total_stake(token_id) >= backing_before, "the vault stopped counting alpha on hotkey 0"

    located_keys = [ZERO_HOTKEY, *hotkeys[1:]]
    exits.unwrap(
        env, token_id, shares // 2, "Zero hotkey: a partial exit should pay from hotkey 0",
        hotkeys=located_keys, label="unwrap [hotkey 0]",
    )
    env.assert_vault_reverts_with(
        "ZeroHotkey()", 1_500_000, "Zero hotkey: a wrap must not name hotkey 0",
        "wrap(uint256,bytes32,uint256)", netuid, ZERO_HOTKEY, 0,
    )
    receipt, _ = exits.unwrap(
        env, token_id, env.vault_shares(token_id), "Zero hotkey: the full exit failed", hotkeys=located_keys,
    )
    assert env.vault_shares(token_id) == 0
    exits.assert_drained(env, token_id, located_keys, receipt, "Zero hotkey: full exit")
