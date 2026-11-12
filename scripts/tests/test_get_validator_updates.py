"""Chainless tests for the registry-update reader's CSV rows."""
import get_validator_updates as script
from fake_events import BLOCK_TIMESTAMP, fake_log


def test_validator_update_rows_carry_the_netuid_nonce_and_block_time(run_event_reader):
    events = {("PlaceholderValidatorRegistry", "ValidatorUpdated"): [
        (fake_log("0x01", 42), {"netuid": 7, "nonce": 2, "hotkey": bytes(32)}),
        (fake_log("0x02", 43), {"netuid": 9, "nonce": 1, "hotkey": bytes(32)}),
    ]}

    rows = run_event_reader(script, ["--registry-address", "registry"], events, 1, 42)

    assert rows == [
        {"tx_hash": "0x01", "netuid": "7", "nonce": "2", "count": "1", "timestamp": str(BLOCK_TIMESTAMP)},
        {"tx_hash": "0x02", "netuid": "9", "nonce": "1", "count": "1", "timestamp": str(BLOCK_TIMESTAMP)},
    ]


def test_validator_updates_of_an_empty_range_print_only_the_header(run_event_reader):
    assert run_event_reader(script, ["--registry-address", "registry"], {}, 1, 42) == []
