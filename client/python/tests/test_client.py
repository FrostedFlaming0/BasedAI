"""Smoke tests for the BasedAI Python client.

These cover the pure, offline-testable surface: the receipt digest (which must
match the Solidity contract and the TypeScript client byte-for-byte), receipt
signing, and the request/response types. Network paths are not exercised.
"""

from __future__ import annotations

import pytest
from eth_abi import encode
from eth_account import Account
from eth_account.messages import encode_defunct
from web3 import Web3

from eth_utils import keccak

from basedai_client.client import DEFAULT_RESERVATION, BasedClient, ClientConfig, _assert_final_receipt_identity, _erc20, _market
from basedai_client.types import InferenceRequest, InferenceResponse, Receipt

# Cross-client golden vector: the same fixed receipt produces this digest in the
# Solidity ComputeUnitMarket, the TypeScript client, and here. Locks the field
# order and ABI types across all three implementations.
GOLDEN_DIGEST = "0xb62ff1422902bee388e9860d6cdeb2b7436eabbe933a4ee24ba5edba86e84fb7"

MARKET = "0x3333333333333333333333333333333333333333"
CHAIN_ID = 763373
# Deterministic, well-known throwaway test key (never used for real funds).
TEST_KEY = "0x0000000000000000000000000000000000000000000000000000000000000001"


def _fixture_receipt() -> Receipt:
    return Receipt(
        user="0x1111111111111111111111111111111111111111",
        miner="0x2222222222222222222222222222222222222222",
        brain_id=7,
        prompt_hash="0x" + "aa" * 32,
        response_hash="0x" + "bb" * 32,
        amount=1_000_000_000_000_000_000,
        expiry=1893456000,
        nonce=42,
    )


def _canonical_digest(market: str, chain_id: int, r: Receipt) -> str:
    """Independent re-implementation of the on-chain receipt digest (the spec)."""
    digest = Web3.keccak(
        encode(
            [
                "address", "uint256", "address", "address", "uint256",
                "bytes32", "bytes32", "uint256", "uint64", "uint256",
            ],
            [
                market, chain_id, r.user, r.miner, r.brain_id,
                bytes.fromhex(r.prompt_hash[2:]), bytes.fromhex(r.response_hash[2:]),
                r.amount, r.expiry, r.nonce,
            ],
        )
    )
    return "0x" + digest.hex()


def _client(private_key: str | None = TEST_KEY) -> BasedClient:
    return BasedClient(
        ClientConfig(
            rpc_url="http://localhost:8545",  # never dialed in these tests
            chain_id=CHAIN_ID,
            based="0x0000000000000000000000000000000000000bA5",
            subnet_registry="0x0000000000000000000000000000000000005ec0",
            market=MARKET,
            gateway_url="http://localhost:9999",
            private_key=private_key,
        )
    )


class TestReceiptDigest:
    def test_canonical_digest_matches_golden(self):
        # The spec encoding matches the cross-client golden vector.
        assert _canonical_digest(MARKET, CHAIN_ID, _fixture_receipt()) == GOLDEN_DIGEST

    def test_sign_receipt_signs_the_canonical_digest(self):
        client = _client()
        sig = client._sign_receipt(_fixture_receipt())
        recovered = Account.recover_message(
            encode_defunct(bytes.fromhex(GOLDEN_DIGEST[2:])),
            signature=sig,
        )
        # The signature recovers to the signer's account over exactly the golden
        # digest -> the client signs what the contract will verify.
        assert recovered == client.account.address

    def test_sign_receipt_is_deterministic(self):
        client = _client()
        r = _fixture_receipt()
        assert client._sign_receipt(r) == client._sign_receipt(r)

    def test_digest_changes_with_nonce(self):
        base = _canonical_digest(MARKET, CHAIN_ID, _fixture_receipt())
        bumped = _fixture_receipt()
        bumped.nonce = 43
        assert _canonical_digest(MARKET, CHAIN_ID, bumped) != base


class TestAccountGuards:
    def test_no_key_means_no_account(self):
        assert _client(private_key=None).account is None

    def test_balance_requires_account(self):
        with pytest.raises(RuntimeError, match="requires private_key"):
            _client(private_key=None).balance()


class TestReservation:
    def test_final_receipt_cannot_change_nonce(self):
        preauth = _fixture_receipt()
        final = _fixture_receipt()
        final.response_hash = "0x" + "cc" * 32
        final.amount = 123
        _assert_final_receipt_identity(preauth, final)
        final.nonce += 1
        with pytest.raises(RuntimeError, match="identity"):
            _assert_final_receipt_identity(preauth, final)
    def test_default_reservation_is_small(self):
        # 0.01 BASED — a bounded fallback, far below a typical budget.
        assert DEFAULT_RESERVATION == 10**16

    def test_request_reservation_defaults_to_zero(self):
        req = InferenceRequest(brain_id=1, prompt="hi", budget=10**18)
        assert req.reservation == 0  # 0 => client uses DEFAULT_RESERVATION

    def test_sentinel_matches_contract_formula(self):
        # The client's pre-auth sentinel must equal the contract's recomputation
        # keccak256(abi.encodePacked(promptHash, bytes32(nonce))), or the on-chain
        # reservation cap would fail to recognize a pre-auth.
        prompt_hash = "0x" + Web3.keccak(text="hello").hex()
        nonce = 123456789
        client_sentinel = Web3.keccak(hexstr=prompt_hash[2:] + format(nonce, "064x"))
        contract_sentinel = keccak(bytes.fromhex(prompt_hash[2:]) + nonce.to_bytes(32, "big"))
        assert client_sentinel == contract_sentinel


class TestTypes:
    def test_inference_request_defaults(self):
        req = InferenceRequest(brain_id=1, prompt="hi", budget=10)
        assert req.max_tokens == 256
        assert req.temperature == 0.7
        assert req.expiry is None

    def test_inference_response_roundtrips_fields(self):
        resp = InferenceResponse(
            text="ok",
            miner="0x2222222222222222222222222222222222222222",
            prompt_hash="0x" + "aa" * 32,
            response_hash="0x" + "cc" * 32,
            tokens_in=3,
            tokens_out=5,
            amount=10,
            miner_signature="0x" + "dd" * 65,
        )
        assert resp.tokens_in == 3 and resp.tokens_out == 5
        assert resp.amount == 10


class TestContractBuilders:
    def test_erc20_exposes_approve_and_balanceof(self):
        w3 = _client().w3
        c = _erc20(w3, MARKET)
        assert {"approve", "balanceOf"} <= {f.abi["name"] for f in c.all_functions()}

    def test_market_exposes_deposit_withdraw_balances(self):
        w3 = _client().w3
        c = _market(w3, MARKET)
        # Two-step withdrawal: requestWithdraw(amount) then withdraw() (no args).
        assert {"deposit", "requestWithdraw", "withdraw", "balances"} <= {
            f.abi["name"] for f in c.all_functions()
        }

    def test_withdraw_is_two_step_no_amount(self):
        w3 = _client().w3
        c = _market(w3, MARKET)
        withdraw = next(f for f in c.all_functions() if f.abi["name"] == "withdraw")
        # withdraw() takes no arguments now (the contract pays out min(requested, balance)).
        assert withdraw.abi["inputs"] == []
        request = next(f for f in c.all_functions() if f.abi["name"] == "requestWithdraw")
        assert [i["type"] for i in request.abi["inputs"]] == ["uint256"]
