"""Chainless tests for the vault event readers' CSV rows."""
import get_deposits
import get_rebalances
import get_subnet_proxies
import get_unwraps
from fake_events import fake_log

VAULT = ["--vault-address", "vault"]
USER = "0x00000000000000000000000000000000000000AA"
CLONE = "0x00000000000000000000000000000000000000Bb"
FROM_HOTKEY = bytes.fromhex("11" * 32)
TO_HOTKEY = bytes.fromhex("22" * 32)


def test_deposit_rows_carry_user_token_assets_and_shares(run_event_reader):
    events = {("AlphaVault", "Deposited"): [
        (fake_log("0x0a", 5), {"user": USER, "tokenId": 65_543, "assets": 30, "shares": 30_000_000_000}),
    ]}

    rows = run_event_reader(get_deposits, VAULT, events, 3, 9)

    assert rows == [{"tx_hash": "0x0a", "user": USER, "token_id": "65543", "assets": "30", "shares": "30000000000"}]


def test_unwrap_rows_carry_the_observed_alpha_out(run_event_reader):
    events = {("AlphaVault", "Unwrapped"): [
        (fake_log("0x0b", 6), {"user": USER, "tokenId": 7, "shares": 500, "alphaOut": 29, "destinationColdkey": TO_HOTKEY}),
    ]}

    rows = run_event_reader(get_unwraps, VAULT, events, 3, 9)

    assert rows == [{"tx_hash": "0x0b", "user": USER, "token_id": "7", "shares": "500", "alpha_out_rao": "29"}]


def test_rebalance_rows_carry_both_hotkeys_as_hex(run_event_reader):
    events = {("AlphaVault", "Rebalanced"): [
        (fake_log("0x0c", 7), {"tokenId": 7, "fromHotkey": FROM_HOTKEY, "toHotkey": TO_HOTKEY, "amount": 4}),
    ]}

    rows = run_event_reader(get_rebalances, VAULT, events, 3, 9)

    assert rows == [{
        "tx_hash": "0x0c", "token_id": "7", "from_hotkey": "0x" + "11" * 32, "to_hotkey": "0x" + "22" * 32, "amount": "4",
    }]


def test_subnet_proxy_rows_carry_the_token_and_its_clone(run_event_reader):
    events = {("AlphaVault", "SubnetProxyCreated"): [(fake_log("0x0d", 8), {"tokenId": 7, "clone": CLONE})]}

    rows = run_event_reader(get_subnet_proxies, VAULT, events, 3, 9)

    assert rows == [{"tx_hash": "0x0d", "token_id": "7", "clone": CLONE}]


def test_event_readers_print_only_the_header_without_their_own_event(run_event_reader):
    events = {("AlphaVault", "Deposited"): [
        (fake_log("0x0a", 5), {"user": USER, "tokenId": 7, "assets": 30, "shares": 30}),
    ]}

    assert run_event_reader(get_deposits, VAULT, {}, 3, 9) == []
    assert run_event_reader(get_rebalances, VAULT, events, 3, 9) == []
