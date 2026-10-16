from types import SimpleNamespace

import get_vault_state as script


def _registry(hotkeys, weights):
    return SimpleNamespace(functions=SimpleNamespace(
        getValidators=lambda netuid: SimpleNamespace(call=lambda block_identifier: (hotkeys, weights)),
    ))


def test_validator_columns_read_the_two_value_registry():
    hotkey = bytes.fromhex("ab" * 32)

    cols = script._validator_columns(_registry([hotkey], [10_000]), 7, 42)

    assert cols == {"validators_count": 1, "validator_1_hotkey": "0x" + "ab" * 32, "validator_1_weight": 10_000}


def test_validator_columns_without_a_registry_report_no_count():
    assert script._validator_columns(None, 7, 42) == {"validators_count": ""}
