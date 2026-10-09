"""Third-party stake transfers into a subnet clone and a mailbox."""
import pytest

from alpha_e2e import chain, config, extrinsics
from alpha_e2e.substrate import h160_to_ss58, h160_to_substrate_b32

THIRD_PARTY = "//ThirdParty"
THIRD_PARTY_HOTKEY_CAP = 128
DEPOSIT_RAO = 10 * config.RAO_PER_TAO
# The chain refuses a staking precompile call unless the gas left covers its declared weight,
# which prices a full 256-entry StakingHotkeys walk: about 2.3M gas, refunded to actual use.
STAKE_CALL_GAS_LIMIT = 3_000_000


def _staking_hotkey_count(address: str) -> int:
    return len(extrinsics.staking_hotkeys(h160_to_ss58(address)))


def _transfer_under_new_hotkeys(address: str, hotkey_ss58s: list, netuid: int, alpha: int) -> None:
    room = THIRD_PARTY_HOTKEY_CAP - _staking_hotkey_count(address)
    extrinsics.transfer_stakes(h160_to_ss58(address), hotkey_ss58s[:room], netuid, alpha, signer_uri=THIRD_PARTY)
    assert _staking_hotkey_count(address) == THIRD_PARTY_HOTKEY_CAP


def _assert_transfer_refused(address: str, hotkey_ss58: str, netuid: int) -> None:
    with pytest.raises(extrinsics.ExtrinsicError) as refused:
        extrinsics.transfer_stake(h160_to_ss58(address), hotkey_ss58, netuid, DEPOSIT_RAO)
    assert "TooManyStakingHotkeys" in str(refused.value), str(refused.value)


@pytest.mark.scenario
def test_stake_transfers(env):
    clone_netuid, transfer_netuid, mailbox_netuid = env.netuids
    clone_token, transfer_token, _ = env.token_ids
    validator = env.subnet_hotkey_pubkeys(0)[0]
    validator_ss58 = env.hotkey_ss58s[0]

    env.deposit_and_wrap(
        transfer_netuid, env.subnet_hotkey_pubkeys(1)[0], env.hotkey_ss58s[config.VALIDATORS_PER_SUBNET],
        DEPOSIT_RAO, STAKE_CALL_GAS_LIMIT, "wrap failed",
    )
    assert env.vault_shares(transfer_token) > 0

    hotkey_ss58s = [extrinsics.keypair_ss58(f"{THIRD_PARTY}//{i}") for i in range(THIRD_PARTY_HOTKEY_CAP)]
    extrinsics.fund_account(extrinsics.keypair_ss58(THIRD_PARTY), 10 * config.RAO_PER_TAO)
    extrinsics.associate_hotkeys(hotkey_ss58s, signer_uri=THIRD_PARTY)
    extrinsics.add_stakes(hotkey_ss58s, transfer_netuid, 2 * env.chain_min_stake_tao(), signer_uri=THIRD_PARTY)
    _, transfer_alpha = env.floor_boundary(transfer_netuid, 2 * config.CHAIN_MIN_TRANSFER_RAO)

    clone = env.clone_address(clone_token)
    _transfer_under_new_hotkeys(clone, hotkey_ss58s, transfer_netuid, transfer_alpha)
    _assert_transfer_refused(clone, validator_ss58, clone_netuid)

    mailbox = env.mailbox_address(clone_netuid)
    extrinsics.transfer_stake(h160_to_ss58(mailbox), validator_ss58, clone_netuid, DEPOSIT_RAO)
    deposit = env.stake(validator, h160_to_substrate_b32(mailbox), clone_netuid)
    receipt = env.vault_send_expect_revert(
        STAKE_CALL_GAS_LIMIT, "wrap succeeded", "wrap(uint256,bytes32,uint256)", clone_netuid, validator, 0,
    )
    assert chain.receipt_gas_used(receipt) > config.WRAP_GAS_BOUND, "wrap reverted before the transfer"

    before = env.stake(validator, env.wrapper_substrate_coldkey, clone_netuid)
    env.vault_send(
        STAKE_CALL_GAS_LIMIT, "reclaim failed",
        "reclaimAlphaFromMailbox(uint256,bytes32,bytes32)", clone_netuid, validator, env.wrapper_substrate_coldkey,
    )
    received = env.stake(validator, env.wrapper_substrate_coldkey, clone_netuid) - before
    assert received >= deposit - config.ROUNDING_DUST_SLOT_RAO

    user_mailbox = env.mailbox_address(mailbox_netuid)
    _transfer_under_new_hotkeys(user_mailbox, hotkey_ss58s, transfer_netuid, transfer_alpha)
    _assert_transfer_refused(
        user_mailbox, env.hotkey_ss58s[2 * config.VALIDATORS_PER_SUBNET], mailbox_netuid,
    )
