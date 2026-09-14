"""Chainless tests for the wallet the suite generates: it never touches a key it did not make."""
import os

import pytest

from alpha_e2e import bootstrap, chain, config, validators


def _refuse_btcli(monkeypatch):
    def refuse(args, **kwargs):
        raise AssertionError(f"btcli was invoked: {args}")

    monkeypatch.setattr(chain, "btcli_local", refuse)


def test_ensure_alice_wallet_keeps_a_private_key_that_lacks_its_public_file(tmp_path, monkeypatch):
    wallet_dir = tmp_path / config.ALICE_WALLET
    wallet_dir.mkdir()
    (wallet_dir / "coldkey").write_text("someone's key")
    monkeypatch.setattr(config, "WALLET_PATH", str(tmp_path))
    _refuse_btcli(monkeypatch)

    with pytest.raises(RuntimeError, match="without a readable coldkeypub"):
        bootstrap._ensure_alice_wallet()
    assert (wallet_dir / "coldkey").read_text() == "someone's key"


def test_ensure_alice_wallet_keeps_a_foreign_coldkey(tmp_path, monkeypatch):
    wallet_dir = tmp_path / config.ALICE_WALLET
    wallet_dir.mkdir()
    (wallet_dir / "coldkeypub.txt").write_text('{"ss58Address": "5Foreign"}')
    monkeypatch.setattr(config, "WALLET_PATH", str(tmp_path))
    _refuse_btcli(monkeypatch)

    with pytest.raises(RuntimeError, match="not the dev Alice"):
        bootstrap._ensure_alice_wallet()


def test_ensure_alice_wallet_generates_only_into_an_absent_directory(tmp_path, monkeypatch):
    wallet_dir = tmp_path / config.ALICE_WALLET
    monkeypatch.setattr(config, "WALLET_PATH", str(tmp_path))
    commands = []

    def record(args, **kwargs):
        commands.append(args)
        if args[:2] == ["wallet", "regen-coldkey"]:
            wallet_dir.mkdir()
            (wallet_dir / "coldkeypub.txt").write_text(config.ALICE_COLDKEY_SS58)
        else:
            os.makedirs(wallet_dir / "hotkeys", exist_ok=True)
            (wallet_dir / "hotkeys" / config.ALICE_HOTKEY_NAME).write_text("{}")

    monkeypatch.setattr(chain, "btcli_local", record)

    bootstrap._ensure_alice_wallet()

    assert commands[0][:2] == ["wallet", "regen-coldkey"]
    assert "--overwrite" not in commands[0]
    assert commands[1][:2] == ["wallet", "new-hotkey"]


def test_bootstrap_deploys_basic_and_configures_one_validator_per_subnet(monkeypatch):
    deployments, updates = [], []

    def create(artifact, **kwargs):
        deployments.append((artifact, kwargs))
        return artifact.split(":")[-1]

    monkeypatch.setattr(chain, "forge_create", create)
    monkeypatch.setattr(chain, "forge_build", lambda: None)
    monkeypatch.setattr(chain, "cast_block_number", lambda: 42)
    monkeypatch.setattr(chain, "cast_call", lambda *args: "65543")
    monkeypatch.setattr(validators, "set_basic_validator", lambda *args: updates.append(args))
    result = bootstrap._deploy_contracts([7, 8], ["A", "B", "C", "D", "E", "F"], recovery_window=180)
    assert result[3].validator_registry_address == "BasicValidatorRegistry"
    registry_deploy = next(kwargs for artifact, kwargs in deployments if artifact.endswith(":BasicValidatorRegistry"))
    vault_deploy = next(kwargs for artifact, kwargs in deployments if artifact.endswith(":AlphaVault"))
    assert vault_deploy["constructor_args"][3] == "BasicValidatorRegistry"
    assert registry_deploy["constructor_args"] == [config.DEPLOYER_ADDRESS]
    assert updates == [("BasicValidatorRegistry", 7, "A"), ("BasicValidatorRegistry", 8, "D")]


@pytest.mark.parametrize("receipt_status", ["0x1", "0x0"])
def test_build_environment_prepares_protected_mailboxes_before_returning(monkeypatch, receipt_status):
    netuids = [7, 8]
    token_ids = [65543, 65544]
    contracts = bootstrap.DeployedContracts("vault", "lens", "mailbox", "subnet", "registry")
    for name in ("_check_repo_root", "_check_chain_reachable", "_ensure_alice_wallet",
                 "_ensure_evm_account_funded", "_stake_validators"):
        monkeypatch.setattr(bootstrap, name, lambda *args, **kwargs: None)
    monkeypatch.setattr(bootstrap, "_create_subnets", lambda: netuids)
    monkeypatch.setattr(bootstrap, "_register_validators", lambda ids: ([], [], []))
    monkeypatch.setattr(bootstrap, "_deploy_contracts", lambda *args, **kwargs: (1, 2, 3, contracts, token_ids))
    calls = []

    def send(address, signature, netuid, uid, **kwargs):
        assert address == contracts.vault_address
        assert signature == "createMailbox(uint256,bytes32)"
        assert kwargs["private_key"] == config.WRAPPER_USER_PRIVATE_KEY
        assert uid.startswith("0x") and len(bytes.fromhex(uid[2:])) == 32
        calls.append((netuid, uid))
        return {"status": receipt_status}

    monkeypatch.setattr(chain, "cast_send", send)
    if receipt_status == "0x0":
        with pytest.raises(RuntimeError, match="createMailbox failed for netuid 7"):
            bootstrap.build_environment()
        assert [netuid for netuid, uid in calls] == [7]
    else:
        env = bootstrap.build_environment()
        assert env.netuids == netuids
        assert env.token_ids == token_ids
        assert env.vault_address == contracts.vault_address
        assert [netuid for netuid, uid in calls] == netuids
        assert len({uid for netuid, uid in calls}) == len(netuids)
