"""Selling a crumb frees the staking-list entry it pinned, except on the root subnet.

A stranger sends crumbs to a fresh coldkey: one on a dynamic subnet under one validator and
one on the root subnet under a validator that earns root dividends. The coldkey sells both in
full. The dynamic-subnet entry leaves its staking list with the crumb; the root entry stays,
because the chain leaves the pair's root-dividend record off zero.
"""
import pytest

from alpha_e2e import config, extrinsics

ROOT_NETUID = 0
STRANGER = "//RootCrumbStranger"
HOLDER = "//RootCrumbHolder"
ROOT_STAKE_RAO = 5 * config.RAO_PER_TAO
DIVIDEND_EPOCHS = 8


def _epoch_timeout(netuid: int) -> float:
    seconds_per_block, tempo, _ = extrinsics.epoch_schedule(netuid)
    return seconds_per_block * (tempo + 2) + config.EPOCH_MARGIN_SECONDS


@pytest.mark.scenario
def test_selling_a_crumb_frees_its_entry_except_on_root(env):
    netuid = env.netuids[0]
    root_validator, root_validator_ss58 = env.hotkey_pubkeys[0], env.hotkey_ss58s[0]
    subnet_validator, subnet_validator_ss58 = env.hotkey_pubkeys[1], env.hotkey_ss58s[1]
    holder_ss58, holder = extrinsics.keypair_ss58(HOLDER), extrinsics.keypair_pubkey(HOLDER)
    extrinsics.fund_account(extrinsics.keypair_ss58(STRANGER), 20 * config.RAO_PER_TAO)
    extrinsics.fund_account(holder_ss58, config.RAO_PER_TAO)
    extrinsics.enable_subtoken(ROOT_NETUID)

    extrinsics.add_stake(root_validator_ss58, ROOT_NETUID, ROOT_STAKE_RAO, signer_uri=STRANGER)
    for _ in range(DIVIDEND_EPOCHS):
        if extrinsics.root_dividend_rate_bits(root_validator_ss58) != 0:
            break
        extrinsics.wait_for_epoch(netuid, _epoch_timeout(netuid))
        extrinsics.add_stake(root_validator_ss58, ROOT_NETUID, env.chain_min_stake_tao(), signer_uri=STRANGER)
    assert extrinsics.root_dividend_rate_bits(root_validator_ss58) != 0, (
        f"the root validator earned no root dividends within {DIVIDEND_EPOCHS} epochs"
    )

    root_crumb = 2 * env.chain_min_transfer_tao()
    extrinsics.transfer_stake(holder_ss58, root_validator_ss58, ROOT_NETUID, root_crumb, signer_uri=STRANGER)
    extrinsics.add_stake(subnet_validator_ss58, netuid, config.RAO_PER_TAO, signer_uri=STRANGER)
    _, subnet_crumb = env.floor_boundary(netuid, 2 * env.chain_min_transfer_tao())
    extrinsics.transfer_stake(holder_ss58, subnet_validator_ss58, netuid, subnet_crumb, signer_uri=STRANGER)
    assert len(extrinsics.staking_hotkeys(holder_ss58)) == 2, "each crumb lists its validator"

    extrinsics.remove_stake(
        subnet_validator_ss58, netuid, env.stake(subnet_validator, holder, netuid), signer_uri=HOLDER,
    )
    assert env.stake(subnet_validator, holder, netuid) == 0, "the subnet crumb was not sold in full"
    assert len(extrinsics.staking_hotkeys(holder_ss58)) == 1, "selling the subnet crumb did not free its entry"

    extrinsics.remove_stake(
        root_validator_ss58, ROOT_NETUID, env.stake(root_validator, holder, ROOT_NETUID), signer_uri=HOLDER,
    )
    assert env.stake(root_validator, holder, ROOT_NETUID) == 0, "the root crumb was not sold in full"
    record = extrinsics.root_dividend_record(root_validator_ss58, holder_ss58)
    assert record != 0, "the root-dividend record returned to zero"
    assert len(extrinsics.staking_hotkeys(holder_ss58)) == 1, "selling the root crumb freed its entry"
    print(f"  root-dividend record left at {record}; the root validator stays listed with no stake")
