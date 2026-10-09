"""The deployed-localnet handle every scenario drives.

Environment bundles the addresses and ids produced by
bootstrap.build_environment() with typed on-chain getters (stakes, shares,
prices, quotes) and scenario actions (vault sends, deposits, share transfers,
validator rotations, revert assertions).
"""
import math
import secrets
import time
from dataclasses import dataclass
from typing import List, Optional, Tuple

from . import chain, config, extrinsics, substrate, validators


def netuid_of(token_id: int) -> int:
    return token_id & ((1 << config.NETUID_BITS) - 1)


def read_stake(hotkey_pubkey: str, coldkey_pubkey: str, netuid: int, block: Optional[int] = None) -> int:
    """Alpha stake (RAO) for a single (hotkey, coldkey, netuid) from the
    staking precompile, live or as of `block`."""
    return int(chain.cast_call(
        config.STAKING_PRECOMPILE, "getStake(bytes32,bytes32,uint256)(uint256)",
        hotkey_pubkey, coldkey_pubkey, netuid, block=block,
    ))


@dataclass
class Environment:
    netuids: List[int]
    token_ids: List[int]
    # Flat, parallel lists: index = subnet_index * VALIDATORS_PER_SUBNET + validator_index.
    hotkey_pubkeys: List[str]
    hotkey_ss58s: List[str]
    vault_address: str
    lens_address: str
    validator_registry_address: str
    wrapper_substrate_coldkey: str
    observation_block_start: int
    registry_block_start: int
    registry_block_end: int

    # --- On-chain getters -----------------------------------------------------
    def subnet_hotkey_pubkeys(self, subnet_index: int) -> List[str]:
        """The three validator hotkeys registered on the subnet at `subnet_index`."""
        start = subnet_index * config.VALIDATORS_PER_SUBNET
        return self.hotkey_pubkeys[start:start + config.VALIDATORS_PER_SUBNET]

    def stake(self, hotkey_pubkey: str, coldkey_pubkey: str, netuid: int, block: Optional[int] = None) -> int:
        """Alpha stake (RAO) for a single (hotkey, coldkey, netuid) from the
        staking precompile, live or as of `block`."""
        return read_stake(hotkey_pubkey, coldkey_pubkey, netuid, block)

    def total_stake_across(
        self, coldkey_pubkey: str, netuid: int, hotkey_pubkeys: List[str], block: Optional[int] = None,
    ) -> int:
        """Total alpha stake (RAO) for a coldkey summed across hotkeys on a subnet."""
        return sum(
            self.stake(hotkey_pubkey, coldkey_pubkey, netuid, block)
            for hotkey_pubkey in hotkey_pubkeys
        )

    def stake_change(self, coldkey_pubkey: str, netuid: int, hotkey_pubkeys: List[str], block: int) -> int:
        """How much the coldkey's stake across `hotkey_pubkeys` grew in `block` (negative when
        it shrank)."""
        return (
            self.total_stake_across(coldkey_pubkey, netuid, hotkey_pubkeys, block)
            - self.total_stake_across(coldkey_pubkey, netuid, hotkey_pubkeys, block - 1)
        )

    def vault_shares(
        self, token_id: int, holder: Optional[str] = None, block: Optional[int] = None,
    ) -> int:
        """ERC1155 share balance of `holder` (default: the wrapper user), live or as of
        `block`."""
        return int(chain.cast_call(
            self.vault_address, "balanceOf(address,uint256)(uint256)",
            holder or config.WRAPPER_USER_ADDRESS, token_id, block=block,
        ))

    def vault_total_supply(self, token_id: int, block: Optional[int] = None) -> int:
        """Total shares of a token id, live or as of `block`."""
        return int(chain.cast_call(
            self.vault_address, "totalSupply(uint256)(uint256)", token_id, block=block,
        ))

    def vault_total_stake(self, token_id: int) -> int:
        """The lens's count of the alpha (RAO) backing a token id."""
        return int(chain.cast_call(
            self.lens_address, "totalStake(uint256)(uint256)", token_id,
        ))

    def vault_located_stake(self, token_id: int) -> int:
        """Alpha (RAO) the vault can find for a token id, whether or not that is all of it.
        Answers where `vault_total_stake` refuses."""
        return int(chain.cast_call(
            self.lens_address, "locatedStake(uint256)(uint256)", token_id,
        ))

    def backing_intact(self, token_id: int) -> bool:
        """Whether the vault can account for the alpha it expects under every validator
        it records."""
        return chain.cast_call(
            self.lens_address, "isBackingIntact(uint256)(bool)", token_id,
        ).strip() == "true"

    def write_off_deadline(self, token_id: int) -> int:
        """Write-off deadline of a declared shortfall; max uint256 while a shortfall is
        undeclared, 0 while backing is intact. Expiry lets syncBacking write the deficit
        off; it does not reopen the token by itself."""
        return int(chain.cast_call(
            self.lens_address, "writeOffDeadline(uint256)(uint256)", token_id,
        ))

    def sync_backing(self, token_id: int, label: Optional[str] = None) -> dict:
        """Secure located backing and start, collect into, or finalize a fixed recovery window."""
        return self.vault_send(
            4_000_000, "syncBacking failed", "syncBacking(uint256)", token_id, label=label,
        )

    def recover_stray(self, token_id: int, source_pubkey: str, message: str) -> dict:
        """Collect one source; sync must declare any shortfall first."""
        return self.vault_send(
            4_000_000, message, "recoverStray(uint256,bytes32)", token_id, source_pubkey,
            label="recoverStray",
        )

    def awaiting_attestation(self, token_id: int) -> bool:
        """Whether the position rests on the parking hotkey with deposits and alignment shut
        until the registry publishes a newer set."""
        return chain.cast_call(
            self.vault_address, "awaitingAttestation(uint256)(bool)", token_id,
        ).strip() == "true"

    def parking_hotkey(self) -> str:
        return chain.cast_call(self.vault_address, "parkingHotkey()(bytes32)")

    def mailbox_address(self, netuid: int, user: Optional[str] = None) -> str:
        """Accepted mailbox address for `user`; zero until explicit preparation."""
        return chain.cast_call(
            self.vault_address, "getDepositAddress(address,uint256)(address)",
            user or config.WRAPPER_USER_ADDRESS, netuid,
        )

    def mailbox_coldkey(self, netuid: int, user: Optional[str] = None) -> str:
        """Substrate coldkey a user's mailbox stakes under."""
        return substrate.h160_to_substrate_b32(self.mailbox_address(netuid, user))

    def clone_address(self, token_id: int) -> str:
        """Per-token subnet clone address holding the position's alpha."""
        return chain.cast_call(
            self.vault_address, "subnetClone(uint256)(address)", token_id,
        )

    def clone_coldkey(self, token_id: int) -> str:
        """Substrate coldkey a token's subnet clone stakes under, needed to read
        its on-chain stake."""
        return substrate.h160_to_substrate_b32(self.clone_address(token_id))

    def preview_wrap(self, token_id: int, assets: int) -> int:
        """Shares a deposit of `assets` alpha would mint, the quote a caller sizes
        their `minSharesOut` from."""
        return int(chain.cast_call(
            self.lens_address, "previewWrap(uint256,uint256)(uint256)", token_id, assets,
        ))

    def preview_unwrap(self, token_id: int, shares: int) -> Tuple[int, int]:
        """(alpha RAO, native-TAO wei) legs an unwrap of `shares` would pay out."""
        lines = chain.cast_call_lines(
            self.lens_address, "previewUnwrap(uint256,uint256)(uint256,uint256)",
            token_id, shares,
        )
        return int(lines[0]), int(lines[1])

    def chain_min_stake_tao(self) -> int:
        """The minimum exposed by the staking precompile."""
        return int(chain.cast_call(config.STAKING_PRECOMPILE, "getDefaultMinStake()(uint256)"))

    def hotkey_in_last_seen(self, token_id: int, hotkey_pubkey: str) -> bool:
        """Whether the vault's remembered validator set still references `hotkey_pubkey`."""
        remembered = chain.cast_call_raw(
            self.lens_address, "lastSeenHotkeys(uint256)(bytes32[])", token_id,
        )
        return hotkey_pubkey.removeprefix("0x").lower() in remembered.lower()

    def alpha_price(self, netuid: int) -> int:
        """Current alpha price for a subnet (TAO per alpha, e18 scale)."""
        return int(chain.cast_call(
            config.ALPHA_PRECOMPILE, "getAlphaPrice(uint16)(uint256)", netuid,
        ))

    def alpha_in_pool(self, netuid: int) -> int:
        """Alpha sitting in a subnet's pool (RAO), the chain's liquidity bound for swaps."""
        return int(chain.cast_call(
            config.ALPHA_PRECOMPILE, "getAlphaInPool(uint16)(uint64)", netuid,
        ))

    def alpha_to_tao_quote(self, netuid: int, alpha_rao: int, block: Optional[int] = None) -> int:
        """Chain's own alpha->TAO quote (RAO out) for selling `alpha_rao` on `netuid`, against
        live reserves or those at `block`. Pin the block when pricing a swap that already ran:
        the curve is concave, so a quote against post-swap reserves understates that swap's
        payout by its own price impact."""
        return int(chain.cast_call(
            config.ALPHA_PRECOMPILE, "simSwapAlphaForTao(uint16,uint64)(uint256)",
            netuid, alpha_rao, block=block,
        ))

    def current_token_id(self, netuid: int) -> int:
        return int(chain.cast_call(self.vault_address, "currentTokenId(uint256)(uint256)", netuid))

    def registration_counter(self, netuid: int) -> int:
        """How many times the chain has registered the netuid."""
        return int(chain.cast_call(
            config.SUBNET_PRECOMPILE, "getRegisteredSubnetCounter(uint16)(uint64)", netuid,
        ))

    def is_subnet_dissolving(self, netuid: int) -> Optional[bool]:
        """Whether the chain still reports the netuid mid-dissolution; None when
        the probe fails (the RPC can flap while the chain tears a subnet down)."""
        probe = chain.probe_call(config.SUBNET_PRECOMPILE, "isSubnetDissolving(uint16)(bool)", netuid)
        if probe.returncode != 0:
            return None
        return probe.stdout.strip() == "true"

    def wait_for_dissolution_cleanup(self, netuid: int, timeout: float = 120) -> None:
        """Block until the chain finishes draining a dissolved netuid.

        The dissolve extrinsic only starts the drain, and the vault freezes the
        subnet's flows until it completes, so scenarios must wait it out before
        asserting refunds. A failed probe counts as still dissolving."""
        deadline = time.monotonic() + timeout
        while self.is_subnet_dissolving(netuid) is not False:
            if time.monotonic() > deadline:
                raise AssertionError(
                    f"netuid {netuid} still dissolving (or subnet precompile unreachable) after {timeout}s"
                )
            chain.wait_for_blocks(1, timeout=config.BLOCK_TIMEOUT_SECONDS)

    def alpha_value_tao(self, netuid: int, alpha_rao: int) -> int:
        """Spot TAO value (RAO) of an alpha amount at the current oracle price."""
        return alpha_rao * self.alpha_price(netuid) // config.ALPHA_PRICE_SCALE

    def floor_boundary(self, netuid: int, floor_rao: int) -> Tuple[int, int]:
        """(alpha price, boundary): the smallest alpha-RAO deposit whose TAO value
        clears `floor_rao` at the current price."""
        price = self.alpha_price(netuid)
        assert price != 0, f"netuid {netuid}: alpha price reads 0 (oracle unavailable)"
        boundary = (floor_rao * config.ALPHA_PRICE_SCALE + price - 1) // price
        return price, boundary

    def holder_assets(self, token_id: int, holder: str) -> int:
        """A holder's pro-rata alpha backing (RAO) by the lens's count."""
        shares = self.vault_shares(token_id, holder)
        supply = self.vault_total_supply(token_id)
        total = self.vault_total_stake(token_id)
        return 0 if supply == 0 else shares * total // supply

    def user_tao_wei(self) -> int:
        """The wrapper user's native TAO balance, in wei."""
        return chain.cast_balance_wei(config.WRAPPER_USER_ADDRESS)

    # --- Vault transactions -----------------------------------------------------
    @staticmethod
    def _gas_label(signature: str, message: str, label: Optional[str]) -> str:
        """What a call's gas is reported under: an explicit label, else the function
        name tagged with the scenario the assertion message names."""
        if label:
            return label
        name = signature.split("(")[0]
        tag = message.split(":")[0].strip() if ":" in message else ""
        return f"{name} [{tag}]" if 0 < len(tag) <= 28 else name

    def vault_broadcast(
        self, gas_limit: int, signature: str, *args,
        private_key: Optional[str] = None, label: Optional[str] = None,
    ) -> dict:
        """Broadcast a vault transaction and return its mined receipt. Every call reports its gas
        under `label`, defaulting to the function name being called."""
        receipt = chain.cast_send(
            self.vault_address, signature, *args,
            private_key=private_key or config.WRAPPER_USER_PRIVATE_KEY,
            gas_limit=gas_limit,
        )
        chain.report_gas(label or signature.split("(")[0], receipt, reverted=not chain.receipt_ok(receipt))
        return receipt

    def vault_send(
        self, gas_limit: int, message: str, signature: str, *args,
        private_key: Optional[str] = None, label: Optional[str] = None,
    ) -> dict:
        """Broadcast a vault transaction and assert it succeeded."""
        receipt = self.vault_broadcast(
            gas_limit, signature, *args,
            private_key=private_key, label=self._gas_label(signature, message, label),
        )
        # Composed lazily: the replay only runs when the assertion is already failing.
        assert chain.receipt_ok(receipt), self._revert_detail(message, receipt, signature, args)
        return receipt

    def vault_send_between_epochs(
        self, netuid: int, gas_limit: int, message: str, signature: str, *args,
        private_key: Optional[str] = None, label: Optional[str] = None,
    ) -> dict:
        """`vault_send` timed so that no epoch of `netuid` lands in the transaction's block:
        stake read either side of that block then differs only by what the call moved."""
        seconds_per_block, tempo, last_epoch = extrinsics.epoch_schedule(netuid)
        margin_blocks = 1 + math.ceil(config.EPOCH_MARGIN_SECONDS / seconds_per_block)
        if last_epoch + tempo - chain.cast_block_number() <= margin_blocks:
            extrinsics.wait_for_epoch(netuid, timeout=(tempo + 2) * config.BLOCK_TIMEOUT_SECONDS)
        receipt = self.vault_send(gas_limit, message, signature, *args, private_key=private_key, label=label)
        block = chain.receipt_block_number(receipt, message)
        assert extrinsics.last_epoch_block(netuid, block) < block, (
            f"{message}: netuid {netuid} ran an epoch in block {block}, so stake read across it "
            "includes emissions"
        )
        return receipt

    def _revert_detail(self, message: str, receipt: dict, signature: str, args: tuple) -> str:
        """An unexpected revert reported by name, so a one-off CI failure is diagnosable
        without reproducing the scenario."""
        reason = chain.revert_reason(receipt, self.vault_address, signature, *args)
        return f"{message}: {reason or 'revert reason unavailable'}: {receipt}"

    def assert_vault_reverts_with(
        self, error_signature: str, gas_limit: int, message: str,
        signature: str, *args,
        private_key: Optional[str] = None, sender: Optional[str] = None,
        label: Optional[str] = None,
    ) -> dict:
        """Assert a vault call reverts with a SPECIFIC custom error: an eth_call
        must surface the error (decoded name, or its selector in the revert
        data), then the broadcast must also fail on-chain. A bare status check
        would also pass on gas exhaustion or the wrong revert. Returns the
        broadcast receipt so callers can bound its gas."""
        error_name = error_signature.split("(")[0]
        selector = chain.cast_sig(error_signature)
        probe = chain.probe_call(
            self.vault_address, signature, *args, sender=sender or config.WRAPPER_USER_ADDRESS,
        )
        probe_output = (probe.stdout + probe.stderr).lower()
        assert error_name.lower() in probe_output or selector.lower() in probe_output, (
            f"{message} (missing {error_signature} in: {probe.stdout + probe.stderr})"
        )
        receipt = self.vault_broadcast(
            gas_limit, signature, *args,
            private_key=private_key, label=self._gas_label(signature, message, label),
        )
        assert receipt.get("status") == "0x0", f"{message}: {receipt}"
        return receipt

    # --- Scenario actions -------------------------------------------------------
    def create_mailbox(self, netuid: int, private_key: Optional[str] = None) -> dict:
        """Prepare the caller's protected mailbox (and the subnet clone, for the first caller)
        under a fresh random UID."""
        return self.vault_send(
            2_000_000, f"createMailbox failed for netuid {netuid}", "createMailbox(uint256,bytes32)",
            netuid, "0x" + secrets.token_hex(32), private_key=private_key,
        )

    def transfer_shares(
        self, token_id: int, sender: str, recipient: str, shares: int, message: str,
        *, private_key: str,
    ) -> dict:
        """Move vault shares between holders, as a secondary-market sale would. Resizes
        a holder's slice without touching the alpha price or the vault's on-chain stake."""
        return self.vault_send(
            300_000, message, "safeTransferFrom(address,address,uint256,uint256,bytes)",
            sender, recipient, token_id, shares, "0x",
            private_key=private_key, label="safeTransferFrom (shares)",
        )

    def wrap(
        self, netuid: int, hotkey_pubkey: str, gas_limit: int, message: str,
        private_key: Optional[str] = None, label: Optional[str] = None, min_shares_out: int = 0,
    ) -> dict:
        """Wrap whatever the caller's mailbox holds under `hotkey_pubkey`, in a block that
        `deposited` can measure."""
        return self.vault_send_between_epochs(
            netuid, gas_limit, message, "wrap(uint256,bytes32,uint256)", netuid, hotkey_pubkey, min_shares_out,
            private_key=private_key, label=label,
        )

    def deposited(self, wrap_receipt: dict, netuid: int, hotkey_pubkey: str, user: Optional[str] = None) -> int:
        """Alpha (RAO) a wrap collected, read off the chain: the mailbox's drop in the wrap's block."""
        block = chain.receipt_block_number(wrap_receipt, "wrap")
        return -self.stake_change(self.mailbox_coldkey(netuid, user), netuid, [hotkey_pubkey], block)

    def deposit_and_wrap(
        self, netuid: int, hotkey_pubkey: str, hotkey_ss58: str,
        amount_rao: int, gas_limit: int, message: str,
        user: Optional[str] = None, private_key: Optional[str] = None,
        label: Optional[str] = None, min_shares_out: int = 0,
    ) -> dict:
        """Transfer alpha from Alice into a user's mailbox under a hotkey, then
        wrap it into the vault. Defaults to the wrapper user; pass `user` and
        `private_key` to run it for another holder. Returns the wrap receipt."""
        mailbox = self.mailbox_address(netuid, user)
        clone = self.clone_address(self.current_token_id(netuid))
        if int(mailbox, 16) == 0 or int(clone, 16) == 0:
            self.create_mailbox(netuid, private_key)
            mailbox = self.mailbox_address(netuid, user)
            assert int(mailbox, 16) != 0, "preparation did not create the intended user's mailbox"
        print(f"  Transferring {amount_rao} RAO from Alice -> mailbox under {hotkey_pubkey[:18]}...")
        extrinsics.transfer_stake(
            substrate.h160_to_ss58(mailbox), hotkey_ss58, netuid, amount_rao,
        )
        return self.wrap(
            netuid, hotkey_pubkey, gas_limit, message,
            private_key=private_key, label=label, min_shares_out=min_shares_out,
        )

    def set_validator(self, netuid: int, hotkey: str) -> None:
        validators.set_basic_validator(self.validator_registry_address, netuid, hotkey)

    def crash_price_until_below(
        self, netuid: int, hotkey_pubkey: str, hotkey_ss58: str,
        alpha_rao: int, target_tao_rao: int, context: str,
    ) -> None:
        """Alice sells her stake under the hotkey in pool-bounded chunks until
        `alpha_rao` is worth less than `target_tao_rao` RAO. Chunks are capped at
        a quarter of the pool's alpha so a single sell cannot overshoot the
        target band. Alice's stake under one hotkey can move the price by about
        half, so deeper targets are out of reach."""
        for _ in range(18):
            if self.alpha_value_tao(netuid, alpha_rao) < target_tao_rao:
                return
            alice_stake = self.stake(hotkey_pubkey, config.ALICE_COLDKEY_PUBKEY, netuid)
            pool_alpha = self.alpha_in_pool(netuid)
            chunk = min(alice_stake // 3, max(pool_alpha // 4, 1))
            if chunk == 0:
                break
            try:
                extrinsics.remove_stake(hotkey_ss58, netuid, chunk)
            except extrinsics.ExtrinsicError as error:
                raise AssertionError(f"{context}: alpha sell rejected") from error
        assert self.alpha_value_tao(netuid, alpha_rao) < target_tao_rao, (
            f"{context}: could not crash the price "
            f"({alpha_rao} alpha RAO still worth >= {target_tao_rao} RAO)"
        )
