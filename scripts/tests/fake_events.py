"""Canned event logs for the chainless event-reader tests."""
from types import SimpleNamespace

BLOCK_TIMESTAMP = 1_700_000_000


def fake_log(tx_hash: str, block_number: int) -> dict:
    return {"transactionHash": SimpleNamespace(to_0x_hex=lambda: tx_hash), "blockNumber": block_number}
