"""Localnet dev constants shared by every e2e module.

These are well-known localnet/dev keys (substrate dev Alice, public test
keys), not secrets. The chain, wallets, and contract layout the suite targets
are all deterministic from these values.
"""
import os

CHAIN_ENDPOINT = "ws://127.0.0.1:9944"
RPC_URL = "http://127.0.0.1:9944"

NETUID_BITS = 16
ALPHA_PRICE_SCALE = 10**18
RAO_PER_TAO = 10**9
RAO_PER_ALPHA = 10**9
VIRTUAL_SHARES = 10**9
VIRTUAL_ASSETS = 1
WEI_PER_RAO = 10**9

WALLET_PATH = os.path.abspath(
    os.path.expanduser(
        os.environ.get(
            "ALPHA_E2E_WALLET_PATH",
            os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, ".wallets"),
        )
    )
)
ALICE_WALLET = "alice"
ALICE_HOTKEY_NAME = "default"
ALICE_COLDKEY_SEED = "0xe5be9a5092b81bca64be81d212e7f2f9eba183bb7a90954f7b76361f6edb5c0a"
ALICE_COLDKEY_PUBKEY = "0xd43593c715fdd31c61141abd04a99fd6822c8558854ccde39a5684e7a56da27d"
ALICE_COLDKEY_SS58 = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"

DEPLOYER_ADDRESS = "0x7bD3E0F025FC388e08dd2A63595dbcaB486F335b"
DEPLOYER_PRIVATE_KEY = "0x58a595a0863f6894cf22d465014abf7c7ca5b46fc8dd7e7e932d158002c33039"
DEPLOYER_SS58 = "5CroES7MYzgDoY6VFJct81eEPT2yQH3T6czzfmD5DD78wffA"

WRAPPER_USER_ADDRESS = "0xd10375caed456c5902D7B155117Dd155398145C7"
WRAPPER_USER_PRIVATE_KEY = "0xf784bf897e423437b1d2a1584a7fc5c99b0ec3f34d70ff74a0643094ccfd4bbe"
WRAPPER_USER_SS58 = "5H9xN1Y6KqdhcK9wPqFSPHC7yeaRC5y4CL3nNF2GX6hJrmpT"

SECOND_HOLDER_ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
SECOND_HOLDER_PRIVATE_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

STAKING_PRECOMPILE = "0x0000000000000000000000000000000000000805"
ALPHA_PRECOMPILE = "0x0000000000000000000000000000000000000808"
SUBNET_PRECOMPILE = "0x0000000000000000000000000000000000000803"
RUNTIME_CONFIGURATION_PRECOMPILE = "0x0000000000000000000000000000000000000812"

VALIDATOR_STAKE_TAO = (600, 400, 200)
HOTKEY_SUFFIXES = ("a", "b", "c")
VALIDATORS_PER_SUBNET = len(HOTKEY_SUFFIXES)
DEPOSIT_RAO = 30 * RAO_PER_ALPHA
RECOVERY_WINDOW_SECONDS = 3 * 60 * 60

COMMAND_TIMEOUT_SECONDS = 300
CALL_TIMEOUT_SECONDS = 60
DEPLOY_TIMEOUT_SECONDS = 900
# The localnet makes a block every 12 s, or every 0.25 s with fast blocks.
BLOCK_TIMEOUT_SECONDS = 30
EPOCH_MARGIN_SECONDS = 3

# Gas estimation fails on the Bittensor EVM; legacy transactions with an explicit price work.
EVM_TX_FLAGS = ["--legacy", "--gas-price", "10000000000"]
# AlphaVault's ~22.8 KB runtime costs ~4.6M gas to deposit; 8M also covers the constructor.
FORGE_CREATE_FLAGS = EVM_TX_FLAGS + ["--gas-limit", "8000000", "--broadcast"]

# A rejected precompile dispatch burns all forwarded gas, so a call under its bound never attempted one.
WRAP_GAS_BOUND = 1_000_000
UNWRAP_GAS_BOUND = 1_700_000
REVERT_GAS_BOUND = 500_000
assert REVERT_GAS_BOUND < WRAP_GAS_BOUND < UNWRAP_GAS_BOUND

# The chain's share arithmetic leaves about one RAO behind per move or drain.
ROUNDING_DUST_SLOT_RAO = 2
# A drain touches up to six slots.
ROUNDING_DUST_TOTAL_RAO = ROUNDING_DUST_SLOT_RAO * 6
CONSOLIDATION_ROUNDING_TOLERANCE_RAO = 100
