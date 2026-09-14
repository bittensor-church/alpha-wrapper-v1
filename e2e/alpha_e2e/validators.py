from . import chain, config


class ValidatorUpdateError(RuntimeError):
    pass


def set_basic_validator(
    registry_address: str, netuid: int, hotkey: str, *,
    private_key: str = config.DEPLOYER_PRIVATE_KEY, rpc: str = config.RPC_URL,
) -> str:
    """Submit an immediate single-validator update from the bootstrap owner."""
    receipt = chain.cast_send(
        registry_address, "setValidator(uint256,bytes32)", netuid, hotkey,
        private_key=private_key, gas_limit=500_000, rpc=rpc,
    )
    chain.report_gas("setValidator", receipt, reverted=not chain.receipt_ok(receipt))
    if not chain.receipt_ok(receipt):
        raise ValidatorUpdateError(f"setValidator failed: {receipt}")
    return receipt["transactionHash"]
