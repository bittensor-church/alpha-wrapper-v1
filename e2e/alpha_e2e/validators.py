from typing import List

from . import chain, config

PLACEHOLDER_REGISTRY = "src/PlaceholderValidatorRegistry.sol:PlaceholderValidatorRegistry"
WEIGHTED_REGISTRY = "test/mocks/MockValidatorRegistry.sol:MockValidatorRegistry"
FULL_WEIGHT_BPS = 10_000


class ValidatorUpdateError(RuntimeError):
    pass


def _publish(registry_address: str, private_key: str, rpc: str, signature: str, *args) -> dict:
    name = signature.split("(")[0]
    receipt = chain.cast_send(
        registry_address, signature, *args, private_key=private_key, gas_limit=500_000, rpc=rpc,
    )
    chain.report_gas(name, receipt, reverted=not chain.receipt_ok(receipt))
    if not chain.receipt_ok(receipt):
        raise ValidatorUpdateError(f"{name} failed: {receipt}")
    return receipt


def set_basic_validator(
    registry_address: str, netuid: int, hotkey: str, *,
    private_key: str = config.DEPLOYER_PRIVATE_KEY, rpc: str = config.RPC_URL,
) -> dict:
    """Submit an immediate single-validator update from the bootstrap owner; returns its receipt."""
    return _publish(registry_address, private_key, rpc, "setValidator(uint256,bytes32)", netuid, hotkey)


def set_weighted_validators(
    registry_address: str, netuid: int, hotkeys: List[str], weights: List[int], *,
    private_key: str = config.DEPLOYER_PRIVATE_KEY, rpc: str = config.RPC_URL,
) -> dict:
    """Publish a set on the weighted registry, weights in basis points summing to
    `FULL_WEIGHT_BPS`; returns its receipt."""
    return _publish(
        registry_address, private_key, rpc, "setValidators(uint256,bytes32[],uint16[])", netuid,
        f"[{','.join(hotkeys)}]", f"[{','.join(str(weight) for weight in weights)}]",
    )


def set_sole_validator(registry_address: str, netuid: int, hotkey: str, *, weighted: bool) -> dict:
    """Attest `hotkey` alone at full weight on either registry; returns its receipt."""
    if weighted:
        return set_weighted_validators(registry_address, netuid, [hotkey], [FULL_WEIGHT_BPS])
    return set_basic_validator(registry_address, netuid, hotkey)
