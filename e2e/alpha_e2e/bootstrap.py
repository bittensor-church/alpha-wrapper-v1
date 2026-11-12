"""One-time localnet setup shared by every scenario.

build_environment() brings a fresh localnet to the point where a position can
be deposited:

  pre-flight  chain reachable, dev Alice wallet present (regen from seed if not)
  fund the deployer EVM account from Alice; create 3 subnets, disable the admin
  freeze window, start emissions, stretch each epoch to `EPOCH_SECONDS`, raise the
  per-block registration limit; register 3 validator hotkeys per subnet and stake
  TAO on them at ratio 3:2:1; deploy the contracts and set one validator per subnet
  through the Placeholder owner; fund the wrapper user and prepare its mailbox on
  each subnet.

btcli calls go through chain.btcli() (auto-appends --network) or
chain.btcli_json() where the outcome is read back; wallet regen/creation calls
go through chain.btcli_local() because they touch only local key files and must
not carry the --network flag. Keys live under config.WALLET_PATH.
"""
import math
import os
from dataclasses import replace
from typing import List, NamedTuple, Tuple

from . import chain, config, extrinsics, substrate, validators
from .environment import Environment, random_bytes32, read_stake

EPOCH_SECONDS = 25


class Deployment(NamedTuple):
    vault_address: str
    lens_address: str
    validator_registry_address: str
    token_ids: List[int]
    observation_block_start: int
    registry_block_start: int
    registry_block_end: int
    registry_update_receipts: List[dict]


def _log(message: str) -> None:
    print(f"\n=== {message} ===", flush=True)


def create_subnet() -> int:
    """Create a subnet and return the netuid the chain assigned it."""
    result = chain.btcli_json(
        ["subnets", "create", "--wallet", config.ALICE_WALLET,
         "--wallet-hotkey", config.ALICE_HOTKEY_NAME, "--yes"],
    )
    netuid = result.get("data", {}).get("netuid")
    if netuid is None:
        raise RuntimeError(f"Could not extract netuid: {result}")
    return int(netuid)


# This refusal means the hotkey already holds the slot the call was asked to reach.
_ALREADY_REGISTERED = "HotKeyAlreadyRegisteredInSubNet"


def burned_register_with_retry(hotkey_ss58: str, netuid: int, *, signer_uri: str = "//Alice") -> None:
    """Register a hotkey on a subnet, retrying across blocks: registration is rate-limited even
    at the raised per-block limit."""
    refusal = None
    for attempt in (1, 2, 3):
        try:
            extrinsics.burned_register(hotkey_ss58, netuid, signer_uri=signer_uri)
            return
        except extrinsics.ExtrinsicError as error:
            if _ALREADY_REGISTERED in str(error):
                return
            refusal = error
        print(f"  Retry {attempt} for {hotkey_ss58[:12]}... (waiting for next block)")
        chain.wait_for_blocks(1, timeout=config.BLOCK_TIMEOUT_SECONDS)
    raise RuntimeError(f"register failed for {hotkey_ss58} on netuid {netuid} after 3 attempts: {refusal}")


def register_hotkey(netuid: int, hotkey_name: str) -> Tuple[str, str]:
    """Create the hotkey if missing and register it on a subnet.
    Returns the hotkey's (bytes32 pubkey, SS58 address)."""
    hotkey_file = substrate.hotkey_file_path(config.ALICE_WALLET, hotkey_name)
    if not os.path.isfile(hotkey_file):
        chain.btcli_local(
            ["wallet", "new-hotkey", "--wallet", config.ALICE_WALLET,
             "--wallet-hotkey", hotkey_name, "--n-words", "12"],
        )

    pubkey = substrate.read_hotkey_pubkey(config.ALICE_WALLET, hotkey_name)
    ss58 = substrate.read_hotkey_ss58(config.ALICE_WALLET, hotkey_name)
    burned_register_with_retry(ss58, netuid)
    return pubkey, ss58


def _check_repo_root() -> None:
    if not (os.path.isdir("src") and os.path.isdir("e2e")):
        raise RuntimeError("Run from the repo root (CWD must contain e2e/ and src/).")


def _check_chain_reachable() -> None:
    _log("Pre-flight checks")
    try:
        chain_id = chain.cast_chain_id()
    except chain.ChainError as error:
        raise RuntimeError(f"Cannot connect to {config.RPC_URL}") from error
    print(f"  Chain reachable (chain-id: {chain_id})")


def _ensure_alice_wallet() -> None:
    """Make sure the suite's alice wallet is the dev Alice (generating it from the
    dev seed when it is absent) and has a hotkey."""
    wallet_dir = substrate.wallet_dir_path(config.ALICE_WALLET)
    coldkey_file = substrate.coldkeypub_file_path(config.ALICE_WALLET)
    move_aside = "Move it aside, or point ALPHA_E2E_WALLET_PATH at another directory."

    if os.path.isfile(coldkey_file):
        with open(coldkey_file) as coldkey_pub_file:
            content = coldkey_pub_file.read()
        if config.ALICE_COLDKEY_SS58 not in content:
            raise RuntimeError(f"{wallet_dir} holds a coldkey that is not the dev Alice. {move_aside}")
        print("  Alice coldkey is the dev Alice")
    elif os.path.isdir(wallet_dir) and os.listdir(wallet_dir):
        # A private key with no public file is still a key; only an empty directory is safe to fill.
        raise RuntimeError(f"{wallet_dir} exists without a readable coldkeypub. {move_aside}")
    else:
        print("  Setting up dev Alice wallet from seed...")
        chain.btcli_local(
            ["wallet", "regen-coldkey", "--wallet", config.ALICE_WALLET,
             "--seed", config.ALICE_COLDKEY_SEED, "--no-password"],
        )
        if not os.path.isfile(coldkey_file):
            raise RuntimeError(f"Failed to regenerate the Alice coldkey at {coldkey_file}")
        print("  Alice coldkey regenerated from dev seed (5Grwva...)")

    hotkey_file = substrate.hotkey_file_path(config.ALICE_WALLET, config.ALICE_HOTKEY_NAME)
    if not os.path.isfile(hotkey_file):
        print(f"  Creating hotkey '{config.ALICE_HOTKEY_NAME}' for wallet '{config.ALICE_WALLET}'...")
        chain.btcli_local(
            ["wallet", "new-hotkey", "--wallet", config.ALICE_WALLET,
             "--wallet-hotkey", config.ALICE_HOTKEY_NAME, "--n-words", "12"],
        )
        print(f"  Created hotkey '{config.ALICE_HOTKEY_NAME}'")
    else:
        print(f"  Alice hotkey '{config.ALICE_HOTKEY_NAME}' exists")
    print("  Alice wallet ready")


def _ensure_evm_account_funded(
    label: str, address: str, ss58: str, minimum_tao: int, transfer_tao: int,
) -> None:
    balance_wei = chain.cast_balance_wei(address)
    if balance_wei < minimum_tao * config.RAO_PER_TAO * config.WEI_PER_RAO:
        extrinsics.fund_account(ss58, transfer_tao * config.RAO_PER_TAO)
        print(f"  Transferred {transfer_tao} TAO -> {address} ({ss58})")
    else:
        print(f"  {label} already funded: {balance_wei} wei (>= {minimum_tao} TAO, skipping transfer)")


def _create_subnets() -> List[int]:
    _log("Create 3 subnets")
    netuids = []
    for subnet_number in (1, 2, 3):
        print(f"  Creating subnet {subnet_number} of 3 ...")
        netuid = create_subnet()
        netuids.append(netuid)
        print(f"  netuid {netuid}")

    _log("Disable admin freeze window (deterministic sudo hyperparameter writes)")
    extrinsics.set_admin_freeze_window(0)
    print("  AdminFreezeWindow -> 0")

    _log("Start emissions, stretch the epochs, raise the per-block registration cap")
    for netuid in netuids:
        chain.btcli(
            ["sudo", "start", "--netuid", str(netuid),
             "--wallet", config.ALICE_WALLET, "--wallet-hotkey", config.ALICE_HOTKEY_NAME,
             "--yes"],
            check=True,
        )
        print(f"  netuid {netuid} emissions started")
        seconds_per_block, tempo, _ = extrinsics.epoch_schedule(netuid)
        stretched = max(tempo, math.ceil(EPOCH_SECONDS / seconds_per_block))
        if stretched != tempo:
            extrinsics.set_tempo(netuid, stretched)
        print(f"  netuid {netuid} tempo -> {stretched} blocks")
        extrinsics.set_max_registrations_per_block(netuid, 8)
        print(f"  netuid {netuid} registrations per block -> 8")
    return netuids


def _register_validators(netuids: List[int]) -> Tuple[List[str], List[str]]:
    _log("Hotkeys & validators (3 per subnet)")
    hotkey_pubkeys: List[str] = []
    hotkey_ss58s: List[str] = []

    for subnet_index, netuid in enumerate(netuids):
        for suffix in config.HOTKEY_SUFFIXES:
            hotkey_name = f"hk_e2e_{subnet_index + 1}{suffix}"
            pubkey, ss58 = register_hotkey(netuid, hotkey_name)
            hotkey_pubkeys.append(pubkey)
            hotkey_ss58s.append(ss58)
            print(f"  {hotkey_name} registered on netuid {netuid}: {pubkey[:18]}...")

    return hotkey_pubkeys, hotkey_ss58s


def _stake_validators(
    netuids: List[int], hotkey_pubkeys: List[str], hotkey_ss58s: List[str],
) -> None:
    _log("Stake TAO per validator (ratio 3:2:1)")
    for subnet_index, netuid in enumerate(netuids):
        for validator_index, amount_tao in enumerate(config.VALIDATOR_STAKE_TAO):
            flat_index = subnet_index * config.VALIDATORS_PER_SUBNET + validator_index
            hotkey_pubkey = hotkey_pubkeys[flat_index]

            extrinsics.add_stake(hotkey_ss58s[flat_index], netuid, amount_tao * config.RAO_PER_TAO)
            stake = read_stake(hotkey_pubkey, config.ALICE_COLDKEY_PUBKEY, netuid)
            if stake == 0:
                raise RuntimeError(
                    f"stake add landed but {hotkey_pubkey[:18]}... reads 0 RAO on netuid {netuid}"
                )
            print(f"  netuid {netuid} {hotkey_pubkey[:18]}...: {amount_tao} TAO -> {stake} RAO")


def _deploy_registry() -> str:
    address = chain.forge_create(
        "src/PlaceholderValidatorRegistry.sol:PlaceholderValidatorRegistry",
        private_key=config.DEPLOYER_PRIVATE_KEY,
        constructor_args=[config.DEPLOYER_ADDRESS],
    )
    print(f"  PlaceholderValidatorRegistry: {address} (initial owner={config.DEPLOYER_ADDRESS})")
    return address


def deploy_contracts(
    netuids: List[int], hotkey_pubkeys: List[str], *, recovery_window: int,
) -> Deployment:
    """Deploy the vault, its lens and a Placeholder registry naming each subnet's first hotkey."""
    _log("Deploy")

    observation_block_start = chain.cast_block_number()
    print(f"  Observability block range start: {observation_block_start}")

    chain.forge_build()
    print("  Compiled")

    mailbox_implementation_address = chain.forge_create(
        "src/DepositMailbox.sol:DepositMailbox", private_key=config.DEPLOYER_PRIVATE_KEY,
    )
    print(f"  DepositMailbox: {mailbox_implementation_address}")

    subnet_clone_implementation_address = chain.forge_create(
        "src/SubnetClone.sol:SubnetClone", private_key=config.DEPLOYER_PRIVATE_KEY,
    )
    print(f"  SubnetClone: {subnet_clone_implementation_address}")

    validator_registry_address = _deploy_registry()

    clones_library = "src/libraries/VaultClones.sol:VaultClones"
    clones_address = chain.forge_create(clones_library, private_key=config.DEPLOYER_PRIVATE_KEY)
    print(f"  VaultClones: {clones_address}")
    clones_link = f"{clones_library}:{clones_address}"

    allocation_library = "src/libraries/VaultAllocation.sol:VaultAllocation"
    allocation_address = chain.forge_create(
        allocation_library, private_key=config.DEPLOYER_PRIVATE_KEY, libraries=[clones_link],
    )
    print(f"  VaultAllocation: {allocation_address}")
    allocation_link = f"{allocation_library}:{allocation_address}"

    parking_hotkey = random_bytes32()
    vault_address = chain.forge_create(
        "src/AlphaVault.sol:AlphaVault", private_key=config.DEPLOYER_PRIVATE_KEY,
        libraries=[clones_link, allocation_link],
        constructor_args=[
            "https://example.com/{id}.json", mailbox_implementation_address,
            subnet_clone_implementation_address, validator_registry_address,
            str(recovery_window), parking_hotkey,
        ],
    )
    print(f"  AlphaVault: {vault_address}")

    lens_address = chain.forge_create(
        "src/AlphaVaultLens.sol:AlphaVaultLens", private_key=config.DEPLOYER_PRIVATE_KEY,
        libraries=[allocation_link],
        constructor_args=[vault_address],
    )
    print(f"  AlphaVaultLens: {lens_address}")

    token_ids: List[int] = []
    for netuid in netuids:
        token_id = chain.cast_call(vault_address, "currentTokenId(uint256)(uint256)", netuid)
        if not token_id or token_id == "0":
            raise RuntimeError(
                f"currentTokenId returned 0 for netuid {netuid} (subnet not registered?)"
            )
        token_ids.append(int(token_id))
        print(f"  netuid {netuid} -> tokenId {token_id}")

    registry_block_start = chain.cast_block_number()
    registry_update_receipts = [
        validators.set_basic_validator(
            validator_registry_address, netuid, hotkey_pubkeys[subnet_index * config.VALIDATORS_PER_SUBNET],
        )
        for subnet_index, netuid in enumerate(netuids)
    ]
    registry_block_end = chain.cast_block_number()

    return Deployment(
        vault_address=vault_address,
        lens_address=lens_address,
        validator_registry_address=validator_registry_address,
        token_ids=token_ids,
        observation_block_start=observation_block_start,
        registry_block_start=registry_block_start,
        registry_block_end=registry_block_end,
        registry_update_receipts=registry_update_receipts,
    )


def redeploy(env: Environment, subnet_index: int, recovery_window: int) -> Environment:
    """A fresh vault, lens and registry for the subnet at `subnet_index`, attesting its first hotkey,
    so a scenario can stage the chain before any clone or mailbox exists. The other subnets are
    not attested on the returned deployment."""
    deployment = deploy_contracts(
        [env.netuids[subnet_index]], env.subnet_hotkey_pubkeys(subnet_index), recovery_window=recovery_window,
    )
    return replace(
        env, vault_address=deployment.vault_address, lens_address=deployment.lens_address,
        validator_registry_address=deployment.validator_registry_address,
        observation_block_start=deployment.observation_block_start,
        registry_block_start=deployment.registry_block_start,
        registry_block_end=deployment.registry_block_end,
        registry_update_receipts=deployment.registry_update_receipts,
    )


def build_environment(*, recovery_window: int) -> Environment:
    _check_repo_root()
    _check_chain_reachable()
    _ensure_alice_wallet()
    _log("Fund deployer")
    _ensure_evm_account_funded(
        "Deployer", config.DEPLOYER_ADDRESS, config.DEPLOYER_SS58,
        minimum_tao=50, transfer_tao=10_000,
    )
    netuids = _create_subnets()
    hotkey_pubkeys, hotkey_ss58s = _register_validators(netuids)
    _stake_validators(netuids, hotkey_pubkeys, hotkey_ss58s)
    deployment = deploy_contracts(netuids, hotkey_pubkeys, recovery_window=recovery_window)
    _log("Fund user account")
    _ensure_evm_account_funded(
        "User account", config.WRAPPER_USER_ADDRESS, config.WRAPPER_USER_SS58,
        minimum_tao=5, transfer_tao=100,
    )

    env = Environment(
        netuids=netuids, token_ids=deployment.token_ids,
        hotkey_pubkeys=hotkey_pubkeys, hotkey_ss58s=hotkey_ss58s,
        vault_address=deployment.vault_address,
        lens_address=deployment.lens_address,
        validator_registry_address=deployment.validator_registry_address,
        wrapper_substrate_coldkey=substrate.h160_to_substrate_b32(config.WRAPPER_USER_ADDRESS),
        observation_block_start=deployment.observation_block_start,
        registry_block_start=deployment.registry_block_start,
        registry_block_end=deployment.registry_block_end,
        registry_update_receipts=deployment.registry_update_receipts,
    )
    for netuid in netuids:
        env.create_mailbox(netuid)
        print(f"  Protected mailbox and subnet clone prepared for netuid {netuid}")
    print(f"  Wrapper substrate coldkey: {env.wrapper_substrate_coldkey}")
    return env
