"""Chainless runner for the event-reader scripts: a fake node serves canned events per contract and event."""
import csv
import io
import sys
from types import SimpleNamespace

import pytest
from fake_events import BLOCK_TIMESTAMP


@pytest.fixture
def run_event_reader(monkeypatch, capsys):
    """Run a script's `main` against canned events keyed by (contract, event), served only for the
    block range the command line asks for, and return its CSV output as rows."""
    def run(script, argv, events, block_start, block_end):
        def fetch_event_logs(_w3, _address, contract_name, event_name, start, end, **_options):
            if (start, end) != (block_start, block_end):
                return []
            return events.get((contract_name, event_name), [])

        node = SimpleNamespace(eth=SimpleNamespace(get_block=lambda number: SimpleNamespace(timestamp=BLOCK_TIMESTAMP)))
        monkeypatch.setattr(script, "get_web3_connection", lambda url: node)
        monkeypatch.setattr(script, "fetch_event_logs", fetch_event_logs)
        monkeypatch.setattr(sys, "argv", [
            script.__name__, *argv, "--rpc-url", "http://unused",
            "--block-start", str(block_start), "--block-end", str(block_end),
        ])
        script.main()
        return list(csv.DictReader(io.StringIO(capsys.readouterr().out)))

    return run
