"""Chainless tests for the observability scripts' shared helpers: block ranges, revert names,
position lookup and CSV output."""
import argparse
import io
from dataclasses import dataclass

import pytest
from web3.exceptions import ContractLogicError

import common


def test_block_chunks_covers_the_range_exactly_once():
    assert list(common.block_chunks(0, 9, 4)) == [(0, 3), (4, 7), (8, 9)]


def test_block_chunks_keeps_a_range_that_fits_in_one_request_whole():
    assert list(common.block_chunks(100, 120, 1_000)) == [(100, 120)]


def test_block_chunks_yields_one_window_for_a_single_block():
    assert list(common.block_chunks(7, 7, 10)) == [(7, 7)]


@pytest.mark.parametrize("size", [0, -1])
def test_block_chunks_rejects_a_chunk_size_that_makes_no_progress(size):
    with pytest.raises(ValueError, match="at least 1 block"):
        list(common.block_chunks(0, 10, size))


@pytest.mark.parametrize("block_start,block_end", [(-1, 10), (10, 9)])
def test_fetch_event_logs_rejects_an_impossible_range(block_start, block_end):
    with pytest.raises(ValueError, match="0 <= start <= end"):
        common.fetch_event_logs(None, "0x" + "11" * 20, "AlphaVault", "Deposited", block_start, block_end)


class _MovingHead:
    """A head that advances on every read, the way a live node's does."""

    def __init__(self):
        self.reads = 0

    @property
    def block_number(self):
        self.reads += 1
        return 1_000 + self.reads


class _FakeWeb3:
    def __init__(self):
        self.eth = _MovingHead()


def test_resolve_block_reads_the_head_exactly_once():
    w3 = _FakeWeb3()
    assert common.resolve_block(w3, None) == 1_001
    assert w3.eth.reads == 1


def test_resolve_block_keeps_an_explicit_block_without_touching_the_head():
    w3 = _FakeWeb3()
    assert common.resolve_block(w3, 42) == 42
    assert w3.eth.reads == 0


def test_resolve_block_rejects_a_relative_offset():
    with pytest.raises(ValueError, match="non-negative"):
        common.resolve_block(_FakeWeb3(), -1)


def test_block_number_argument_rejects_a_relative_offset():
    with pytest.raises(argparse.ArgumentTypeError, match="non-negative"):
        common.block_number("-1")
    assert common.block_number("7") == 7


ERRORS_ABI = [
    {"type": "error", "name": "ZeroAmount", "inputs": []},
    {"type": "error", "name": "SlippageExceeded", "inputs": [{"name": "amountOut", "type": "uint256"}]},
    {"type": "function", "name": "wrap", "inputs": []},
]
ZERO_AMOUNT = "0x1f2a2005"
SLIPPAGE_EXCEEDED_5 = "0x72bfa79e" + "00" * 31 + "05"


@pytest.mark.parametrize("data,name", [
    (ZERO_AMOUNT, "ZeroAmount"),
    (SLIPPAGE_EXCEEDED_5, "SlippageExceeded"),
    ({"data": ZERO_AMOUNT}, "ZeroAmount"),
    ("0xDEADBEEF", "0xdeadbeef"),
    (None, "ContractLogicError"),
    ("0x", "ContractLogicError"),
])
def test_extract_error_name_names_the_custom_error_its_selector_or_the_exception(data, name):
    assert common.extract_error_name(ContractLogicError("execution reverted", data=data), ERRORS_ABI) == name


class _Call:
    """A contract call that answers `result`, or reverts with `revert_data`, recording what it was asked with."""

    def __init__(self, result=None, revert_data=None):
        self.result = result
        self.revert_data = revert_data
        self.asked = []

    def call(self, transaction=None, block_identifier=None):
        self.asked.append((transaction, block_identifier))
        if self.revert_data is not None:
            raise ContractLogicError("execution reverted", data=self.revert_data)
        return self.result


def test_dry_run_reports_a_call_that_goes_through_as_none():
    call = _Call(result=1)
    assert common.dry_run(call, 42, ERRORS_ABI) is None
    assert call.asked == [({}, 42)]


def test_dry_run_names_the_error_a_reverting_call_raises():
    call = _Call(revert_data=ZERO_AMOUNT)
    assert common.dry_run(call, 42, ERRORS_ABI, sender="0xabc") == "ZeroAmount"
    assert call.asked == [({"from": "0xabc"}, 42)]


class _Vault:
    """A vault answering `currentTokenId` and `subnetClone` from fixed tables; an unknown netuid
    reverts with SubnetNotRegistered()."""

    abi = [{"type": "error", "name": "SubnetNotRegistered", "inputs": []}]

    def __init__(self, token_ids, clones):
        self.token_ids = token_ids
        self.clones = clones
        self.functions = self

    def currentTokenId(self, netuid):  # noqa: N802 - mirrors the ABI
        if netuid not in self.token_ids:
            return _Call(revert_data="0xee0963b3")
        return _Call(result=self.token_ids[netuid])

    def subnetClone(self, token_id):  # noqa: N802 - mirrors the ABI
        return _Call(result=self.clones.get(token_id, "0x" + "00" * 20))


CLONE = "0x" + "cd" * 20


def test_resolve_position_looks_up_the_live_token_of_a_netuid():
    vault = _Vault({7: 131_079}, {131_079: CLONE})
    assert common.resolve_position(vault, 7, None, 42) == (131_079, 7, CLONE)


def test_resolve_position_takes_a_retired_token_id_as_given():
    vault = _Vault({}, {65_543: CLONE})
    assert common.resolve_position(vault, None, 65_543, 42) == (65_543, 7, CLONE)


def test_resolve_position_exits_for_a_token_without_a_clone():
    with pytest.raises(SystemExit, match="token 65543 has no position"):
        common.resolve_position(_Vault({}, {}), None, 65_543, 42)


def test_lookup_token_id_exits_naming_the_vaults_refusal():
    with pytest.raises(SystemExit, match="netuid 5: SubnetNotRegistered"):
        common.lookup_token_id(_Vault({}, {}), 5)


@dataclass
class _Row:
    token_id: int
    hotkey: str


def test_write_dataclass_csv_writes_the_header_then_each_row_and_counts_them(capsys):
    stream = io.StringIO()
    common.write_dataclass_csv(stream, iter([_Row(7, "0x11"), _Row(9, "0x22")]), _Row, "Deposited")
    assert stream.getvalue().splitlines() == ["token_id,hotkey", "7,0x11", "9,0x22"]
    assert capsys.readouterr().err == "Found 2 Deposited events\n"
