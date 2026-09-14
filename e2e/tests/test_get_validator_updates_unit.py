import sys
from types import SimpleNamespace

import get_validator_updates as script


def test_observability_decodes_basic_validator_updates(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["get_validator_updates", "--registry-address", "registry",
                        "--rpc-url", "http://unused",
                        "--block-start", "1", "--block-end", "42"])
    connection = SimpleNamespace(eth=SimpleNamespace(get_block=lambda number: SimpleNamespace(timestamp=123)))
    monkeypatch.setattr(script, "get_web3_connection", lambda url: connection)
    calls = []
    def logs(*args, **kwargs):
        calls.append(args)
        event = {"netuid": 7, "nonce": 2}
        event.update(hotkey="A", owner="owner")
        return [({"transactionHash": SimpleNamespace(to_0x_hex=lambda: "0x01"), "blockNumber": 42}, event)]
    monkeypatch.setattr(script, "fetch_event_logs", logs)
    script.main()
    contract, event = "BasicValidatorRegistry", "ValidatorUpdated"
    assert calls[0][2:4] == (contract, event)
    assert f"0x01,7,2,1,123" in capsys.readouterr().out
