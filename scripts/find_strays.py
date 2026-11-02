#!/usr/bin/env python3

"""Find the vault's alpha under hotkeys the record does not name, and recover it.

A hotkey swap keeps the clone's alpha under a hotkey the clone stakes under, even
when the chain leaves no edge for the vault to follow. This prints one CSV row per
such hotkey with a pile on the token's subnet, largest pile first so a movable one
can carry smaller ones, with the `recoverStray` dry-run verdict; `--recover` sends
the calls the dry run accepts. Call `syncBacking` first while a shortfall stands,
and again once everything is home.
"""

import argparse
import sys
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from typing import Optional

from web3.exceptions import ContractLogicError

from common import (
    add_block_argument,
    extract_error_name,
    get_web3_connection,
    load_abi,
    lookup_token_id,
    make_csv_writer,
    resolve_block,
)

STAKING_PRECOMPILE = "0x0000000000000000000000000000000000000805"
ADDRESS_MAPPING_PRECOMPILE = "0x000000000000000000000000000000000000080C"
STAKING_LIST_PAGE = 64
STAKING_ABI = [
    {
        "name": "getStakingHotkeys", "type": "function", "stateMutability": "view",
        "inputs": [
            {"name": "coldkey", "type": "bytes32"},
            {"name": "offset", "type": "uint64"},
            {"name": "limit", "type": "uint16"},
        ],
        "outputs": [{"name": "hotkeys", "type": "bytes32[]"}, {"name": "total", "type": "uint64"}],
    },
    {
        "name": "getStake", "type": "function", "stateMutability": "view",
        "inputs": [
            {"name": "hotkey", "type": "bytes32"},
            {"name": "coldkey", "type": "bytes32"},
            {"name": "netuid", "type": "uint256"},
        ],
        "outputs": [{"name": "", "type": "uint256"}],
    },
]
ADDRESS_MAPPING_ABI = [{
    "name": "addressMapping", "type": "function", "stateMutability": "view",
    "inputs": [{"name": "evmAddress", "type": "address"}],
    "outputs": [{"name": "", "type": "bytes32"}],
}]


@dataclass(frozen=True)
class Stray:
    hotkey: bytes
    stake: int


def find_strays(
    listed: Iterable[bytes], recorded: Iterable[bytes], parking: bytes, stake_of: Callable[[bytes], int],
) -> list[Stray]:
    """Listed hotkeys outside the record and parking that hold a pile, largest first."""
    excluded = set(recorded) | {parking}
    strays = []
    for hotkey in dict.fromkeys(listed):
        if hotkey in excluded:
            continue
        stake = stake_of(hotkey)
        if stake:
            strays.append(Stray(hotkey, stake))
    return sorted(strays, key=lambda stray: stray.stake, reverse=True)


def report_rows(strays: Iterable[Stray], verdict_of: Callable[[Stray], Optional[str]]) -> list[dict[str, str]]:
    """One CSV row per stray: the hotkey, its pile, and `ok` or the error `recoverStray` would revert with."""
    return [
        {"hotkey": "0x" + stray.hotkey.hex(), "stake_rao": str(stray.stake), "dry_run": verdict_of(stray) or "ok"}
        for stray in strays
    ]


def listed_hotkeys(staking, coldkey: bytes, block: int | str) -> list[bytes]:
    """The clone's whole staking list, a page at a time."""
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


def dry_run(recover_call, sender: str, block: int | str, abi: list) -> Optional[str]:
    """The error `recoverStray` would revert with, or None when it would go through."""
    try:
        recover_call.call({"from": sender}, block_identifier=block)
        return None
    except ContractLogicError as error:
        return extract_error_name(error, abi)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault-address", required=True, help="AlphaVault contract address")
    parser.add_argument("--rpc-url", required=True, help="HTTP RPC URL of the Subtensor EVM endpoint")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--netuid", type=int, help="Subnet id; resolves the live token id")
    target.add_argument("--token-id", type=int, help="Token id, for a position on a retired generation")
    parser.add_argument("--recover", action="store_true", help="Send recoverStray for each pile the dry run accepts")
    parser.add_argument("--private-key", help="Key of the account that sends recoverStray; needed with --recover")
    parser.add_argument("--gas-limit", type=int, default=4_000_000, help="Gas limit per recoverStray")
    add_block_argument(parser)
    args = parser.parse_args()
    if args.recover and not args.private_key:
        sys.exit("--recover needs --private-key")

    w3 = get_web3_connection(args.rpc_url)
    block = resolve_block(w3, args.block)
    print(f"reading at block {block}", file=sys.stderr)
    vault = w3.eth.contract(address=w3.to_checksum_address(args.vault_address), abi=load_abi("AlphaVault"))
    staking = w3.eth.contract(address=STAKING_PRECOMPILE, abi=STAKING_ABI)
    mapping = w3.eth.contract(address=ADDRESS_MAPPING_PRECOMPILE, abi=ADDRESS_MAPPING_ABI)

    token_id = args.token_id if args.token_id is not None else lookup_token_id(vault, args.netuid, block)
    netuid = token_id & 0xFFFF
    clone = vault.functions.subnetClone(token_id).call(block_identifier=block)
    if int(clone, 16) == 0:
        sys.exit(f"token {token_id} has no position")
    coldkey = mapping.functions.addressMapping(clone).call(block_identifier=block)
    slots = vault.functions.recordedSlots(token_id).call(block_identifier=block)
    parking = vault.functions.parkingHotkey().call(block_identifier=block)
    short_since, _ = vault.functions.recovery(token_id).call(block_identifier=block)

    strays = find_strays(
        listed_hotkeys(staking, coldkey, block),
        (active for _logical, active, _tracked in slots),
        parking,
        lambda hotkey: staking.functions.getStake(hotkey, coldkey, netuid).call(block_identifier=block),
    )
    print(
        "shortfall on file: recovery collects into parking" if short_since else "no shortfall on file: recovery annexes into backing",
        file=sys.stderr,
    )
    sender = w3.eth.account.from_key(args.private_key).address if args.private_key else clone
    rows = report_rows(
        strays, lambda stray: dry_run(vault.functions.recoverStray(token_id, stray.hotkey), sender, "latest", vault.abi),
    )
    writer = make_csv_writer(sys.stdout, ["hotkey", "stake_rao", "dry_run"])
    for row in rows:
        writer.writerow(row)
    if not args.recover:
        return
    for row in rows:
        if row["dry_run"] != "ok":
            continue
        recover_call = vault.functions.recoverStray(token_id, bytes.fromhex(row["hotkey"][2:]))
        tx = recover_call.build_transaction({
            "from": sender, "nonce": w3.eth.get_transaction_count(sender),
            "gas": args.gas_limit, "gasPrice": w3.eth.gas_price, "chainId": w3.eth.chain_id,
        })
        signed = w3.eth.account.sign_transaction(tx, args.private_key)
        receipt = w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(signed.raw_transaction))
        status = "ok" if receipt["status"] == 1 else "reverted"
        print(f"recoverStray({token_id}, {row['hotkey']}): {status} in {receipt['transactionHash'].hex()}", file=sys.stderr)


if __name__ == "__main__":
    main()
