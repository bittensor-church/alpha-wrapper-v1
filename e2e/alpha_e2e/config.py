"""Localnet dev constants shared by every e2e module.

These are well-known localnet/dev keys (substrate dev Alice, public test
keys), not secrets. The chain, wallets, and contract layout the suite targets
are all deterministic from these values.
"""
import os

# --- Chain -------------------------------------------------------------------
CHAIN_ENDPOINT = "ws://127.0.0.1:9944"
RPC_URL = "http://127.0.0.1:9944"

NETUID_BITS = 16
ALPHA_PRICE_SCALE = 10**18
RAO_PER_TAO = 10**9
RAO_PER_ALPHA = 10**9
# Native TAO on the EVM side moves in whole RAO, so every balance is a multiple of this.
WEI_PER_RAO = 10**9

# --- Wallets -----------------------------------------------------------------
# The suite generates and overwrites keys, so it keeps them under a directory of
# its own instead of the operator's btcli wallet directory.
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

# "Wrapper user": the EVM account that deposits and withdraws in every scenario.
WRAPPER_USER_ADDRESS = "0xd10375caed456c5902D7B155117Dd155398145C7"
WRAPPER_USER_PRIVATE_KEY = "0xf784bf897e423437b1d2a1584a7fc5c99b0ec3f34d70ff74a0643094ccfd4bbe"
WRAPPER_USER_SS58 = "5H9xN1Y6KqdhcK9wPqFSPHC7yeaRC5y4CL3nNF2GX6hJrmpT"

# Second holder for multi-holder scenarios: a well-known public test key,
# localnet-only.
SECOND_HOLDER_ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
SECOND_HOLDER_PRIVATE_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

# --- Precompiles -------------------------------------------------------------
STAKING_PRECOMPILE = "0x0000000000000000000000000000000000000805"
# Exposes the chain's own alpha price and alpha->TAO swap simulation.
ALPHA_PRECOMPILE = "0x0000000000000000000000000000000000000808"
# Answers whether a netuid is still mid-dissolution after a dissolve call.
SUBNET_PRECOMPILE = "0x0000000000000000000000000000000000000803"

# --- Seeding amounts ---------------------------------------------------------
VALIDATOR_STAKE_TAO = (600, 400, 200)
HOTKEY_SUFFIXES = ("a", "b", "c")
VALIDATORS_PER_SUBNET = len(HOTKEY_SUFFIXES)
# The standard position a scenario wraps, drawn from Alice's stake under one validator.
DEPOSIT_RAO = 30 * RAO_PER_ALPHA
RECOVERY_WINDOW_SECONDS = 3 * 60 * 60

# --- Foundry / subprocess flags ------------------------------------------------
# A localnet command that stops answering hangs the whole run, so every subprocess
# gets a deadline; builds and deployments compile and broadcast, so they get a
# longer one than a call or a send.
COMMAND_TIMEOUT_SECONDS = 300
CALL_TIMEOUT_SECONDS = 60
DEPLOY_TIMEOUT_SECONDS = 900
# Longest gap between two blocks the suite waits out; the localnet makes one every 12 s, or
# every 0.25 s with fast blocks.
BLOCK_TIMEOUT_SECONDS = 30
# An epoch pays emissions into every stake on its subnet, so a call that stake reads must
# account for exactly waits out the next epoch unless it is due later than this many seconds
# after the block that includes the call.
EPOCH_MARGIN_SECONDS = 3

# Bittensor EVM: gas estimation fails; always use legacy txs with explicit gas.
EVM_TX_FLAGS = ["--legacy", "--gas-price", "10000000000"]
# AlphaVault's runtime is ~22.8 KB, so code deposit alone is ~4.6M gas; the ceiling clears that
# plus constructor and intrinsic while staying well under the block gas limit.
FORGE_CREATE_FLAGS = EVM_TX_FLAGS + ["--gas-limit", "8000000", "--broadcast"]
# The localnet charges a fixed gas price, which payout reconstruction relies on.
LOCALNET_GAS_PRICE_WEI = 10**10

# --- Gas budgets ---------------------------------------------------------------
# A rejected precompile dispatch consumes all forwarded gas, so a call staying far
# under its limit separates a designed pre-check revert (or a healthy call) from an
# attempted-and-burned dispatch.
WRAP_GAS_BOUND = 1_000_000
UNWRAP_GAS_BOUND = 1_700_000
REVERT_GAS_BOUND = 500_000
# Editing one bound without the others can invert the order and make every gas
# assertion vacuous, so the ordering is enforced at import.
assert REVERT_GAS_BOUND < WRAP_GAS_BOUND < UNWRAP_GAS_BOUND

# --- Rounding dust ---------------------------------------------------------------
# The chain's share arithmetic can leave about one RAO behind on every entry a move
# or drain passes through, so a slot the vault emptied legitimately reads a few RAO,
# not always zero.
ROUNDING_DUST_SLOT_RAO = 2
# A position drains across up to six slots, so totals accumulate the per-slot rounding.
ROUNDING_DUST_TOTAL_RAO = ROUNDING_DUST_SLOT_RAO * 6
# A consolidation adds extra move/drain operations, each losing about one RAO to
# integer rounding; conservation checks across a consolidation allow this much slack.
CONSOLIDATION_ROUNDING_TOLERANCE_RAO = 100
