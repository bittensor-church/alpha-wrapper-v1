#!/usr/bin/env python3

"""Find the vault's alpha under hotkeys the record does not name, and recover it.

A hotkey swap keeps the clone's alpha under a hotkey the clone stakes under, even
when the chain leaves no edge for the vault to follow. This prints one CSV row per
such hotkey with a pile above the vault's rounding slack on the token's subnet,
largest pile first, with the `recoverStray` dry-run verdict at the block read. A
hotkey the vault already locates, a followed successor or a listed hotkey holding a
slot's alpha, shows `NothingToRecover` until `syncBacking` records it. `--recover` signs with `RECOVER_PRIVATE_KEY` from the environment and
sends each call the dry run accepts at the head just before sending, so a pile parked
by one call carries the smaller ones; it exits non-zero while any pile stays out.
Call `syncBacking` first while a shortfall stands, and again once everything is home.
"""

import argparse
import os
import sys
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from typing import Optional

from web3.exceptions import Web3Exception

from common import (
    add_block_argument,
    add_target_arguments,
    dry_run,
    get_web3_connection,
    load_abi,
    make_csv_writer,
    resolve_block,
    resolve_position,
)

STAKING_PRECOMPILE = "0x0000000000000000000000000000000000000805"
ADDRESS_MAPPING_PRECOMPILE = "0x000000000000000000000000000000000000080C"
STAKING_LIST_PAGE = 64
PRIVATE_KEY_VARIABLE = "RECOVER_PRIVATE_KEY"
# The vault tolerates this much residue on a collected hotkey; the chain leaves about one RAO per move.
SLACK_RAO = 1_000
# Gas estimation is unreliable on the Bittensor EVM; this covers a move across a full staking list.
DEFAULT_GAS_LIMIT = 6_000_000


@dataclass(frozen=True)
class Stray:
    hotkey: bytes
    stake: int

    @property
    def hotkey_hex(self) -> str:
        return "0x" + self.hotkey.hex()


def find_strays(listed: Iterable[bytes], recorded: Iterable[bytes], stake_of: Callable[[bytes], int]) -> list[Stray]:
    excluded = set(recorded)
    strays = [Stray(hotkey, stake_of(hotkey)) for hotkey in listed if hotkey not in excluded]
    return sorted((stray for stray in strays if stray.stake > SLACK_RAO), key=lambda stray: stray.stake, reverse=True)


def report_rows(strays: Iterable[Stray], verdict_of: Callable[[Stray], Optional[str]]) -> list[dict[str, str]]:
    return [
        {"hotkey": stray.hotkey_hex, "stake_rao": str(stray.stake), "dry_run": verdict_of(stray) or "ok"}
        for stray in strays
    ]


def recover(
    strays: Iterable[Stray], verdict_of: Callable[[Stray], Optional[str]], send: Callable[[Stray], Optional[str]],
) -> dict[Stray, Optional[str]]:
    """Dry-run each pile right before its turn and send the accepted ones; a pile maps to
    the reason it stays out, or None once its send went through."""
    return {stray: verdict_of(stray) or send(stray) for stray in strays}


def listed_hotkeys(staking, coldkey: bytes, block: int | str) -> list[bytes]:
    hotkeys: list[bytes] = []
    offset = 0
    while True:
        page, total = staking.functions.getStakingHotkeys(coldkey, offset, STAKING_LIST_PAGE).call(
            block_identifier=block,
        )
        hotkeys.extend(page)
        offset += len(page)
        if not page or offset >= total:
            return hotkeys


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    add_target_arguments(parser)
    parser.add_argument(
        "--recover", action="store_true",
        help=f"Send recoverStray for each pile the dry run accepts, signed with {PRIVATE_KEY_VARIABLE}",
    )
    parser.add_argument("--gas-limit", type=int, default=DEFAULT_GAS_LIMIT, help="Gas limit per recoverStray")
    add_block_argument(parser)
    args = parser.parse_args()
    private_key = os.environ.get(PRIVATE_KEY_VARIABLE)
    if args.recover and not private_key:
        sys.exit(f"--recover needs {PRIVATE_KEY_VARIABLE} in the environment")
    if args.recover and args.block is not None:
        sys.exit("--recover works at the head; drop --block")

    w3 = get_web3_connection(args.rpc_url)
    block = resolve_block(w3, args.block)
    print(f"reading at block {block}", file=sys.stderr)
    vault = w3.eth.contract(address=w3.to_checksum_address(args.vault_address), abi=load_abi("AlphaVault"))
    staking = w3.eth.contract(address=STAKING_PRECOMPILE, abi=load_abi("IStaking"))
    mapping = w3.eth.contract(address=ADDRESS_MAPPING_PRECOMPILE, abi=load_abi("IAddressMapping"))

    token_id, netuid, clone = resolve_position(vault, args.netuid, args.token_id, block)
    coldkey = mapping.functions.addressMapping(clone).call(block_identifier=block)
    slots = vault.functions.recordedSlots(token_id).call(block_identifier=block)
    short_since, _ = vault.functions.recovery(token_id).call(block_identifier=block)

    strays = find_strays(
        listed_hotkeys(staking, coldkey, block),
        (staked_under for _attested, staked_under, _tracked in slots),
        lambda hotkey: staking.functions.getStake(hotkey, coldkey, netuid).call(block_identifier=block),
    )
    print(
        "shortfall on file: recovery collects into parking" if short_since else "no shortfall on file: recovery annexes into backing",
        file=sys.stderr,
    )

    def verdict_at(at: int | str) -> Callable[[Stray], Optional[str]]:
        return lambda stray: dry_run(vault.functions.recoverStray(token_id, stray.hotkey), at, vault.abi)

    writer = make_csv_writer(sys.stdout, ["hotkey", "stake_rao", "dry_run"])
    for row in report_rows(strays, verdict_at(block)):
        writer.writerow(row)
    if not args.recover:
        return

    account = w3.eth.account.from_key(private_key)

    def send(stray: Stray) -> Optional[str]:
        try:
            tx = vault.functions.recoverStray(token_id, stray.hotkey).build_transaction({
                "from": account.address, "nonce": w3.eth.get_transaction_count(account.address),
                "gas": args.gas_limit, "gasPrice": w3.eth.gas_price, "chainId": w3.eth.chain_id,
            })
            receipt = w3.eth.wait_for_transaction_receipt(
                w3.eth.send_raw_transaction(account.sign_transaction(tx).raw_transaction),
            )
        except Web3Exception as error:
            return f"failed: {error}"
        tx_hash = receipt["transactionHash"].to_0x_hex()
        if receipt["status"] != 1:
            return f"reverted in {tx_hash}"
        print(f"recoverStray({token_id}, {stray.hotkey_hex}): ok in {tx_hash}", file=sys.stderr)
        return None

    left_out = {stray: reason for stray, reason in recover(strays, verdict_at("latest"), send).items() if reason}
    for stray, reason in left_out.items():
        print(f"recoverStray({token_id}, {stray.hotkey_hex}): {reason}", file=sys.stderr)
    if left_out:
        sys.exit(f"{len(left_out)} pile(s) not recovered")


if __name__ == "__main__":
    main()
