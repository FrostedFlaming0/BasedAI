#!/usr/bin/env python3
# ruff: noqa: E402
"""Deterministic local devnet E2E smoke flow.

This intentionally avoids GPU/model downloads and public RPCs. It composes the real HTTP gateway,
miner transport, validator aggregator service, signed announces, signed receipts, canonical score
candidate aggregation, gateway cursor restart recovery, and failure cases in one reproducible run.

Run from the repo root:

    PYTHONPATH=client/python:gateway/src:miner/src:validator/src python scripts/devnet_e2e.py
"""

from __future__ import annotations

import asyncio
import json
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
for rel in ("client/python", "gateway/src", "miner/src", "validator/src"):
    sys.path.insert(0, str(REPO / rel))

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer
from eth_account import Account
from eth_utils import keccak
from web3 import Web3

from basedai_client.client import _assert_final_receipt_identity
from basedai_client.types import Receipt
from basedai_gateway.announce import sign_announce
from basedai_gateway.indexer import MemberIndex
from basedai_gateway.server import CursorStore, make_app
from basedai_miner.http_server import make_miner_app
from basedai_miner.receipts import receipt_digest, verify_user_signature
from basedai_validator.aggregator import CanonicalCandidatePool, CommitmentAggregator
from basedai_validator.commitment import sign_commitment
from basedai_validator.service import make_aggregator_app


CHAIN_ID = 57073
BRAIN_ID = 8
MARKET = "0x" + "33" * 20
SCORING = "0x" + "ab" * 20
PRICE_PER_BYTE = 7
PRICE_PER_REQUEST = 101


def _serialize(r: Receipt) -> dict:
    return {
        "user": r.user,
        "miner": r.miner,
        "brain_id": r.brain_id,
        "prompt_hash": r.prompt_hash,
        "response_hash": r.response_hash,
        "amount": r.amount,
        "expiry": r.expiry,
        "nonce": r.nonce,
    }


def _user_sig(account, r: Receipt) -> str:
    from eth_account.messages import encode_defunct

    return account.sign_message(encode_defunct(receipt_digest(MARKET, CHAIN_ID, r))).signature.hex()


async def _started(app: web.Application) -> TestClient:
    client = TestClient(TestServer(app))
    await client.start_server()
    return client


async def main() -> None:
    user = Account.from_key("0x" + "01".zfill(64))
    miner = Account.from_key("0x" + "02".zfill(64))
    v1 = Account.from_key("0x" + "03".zfill(64))
    v2 = Account.from_key("0x" + "04".zfill(64))

    balances = {user.address.lower(): 10**18}
    redeemed: list[Receipt] = []
    settled: list[Receipt] = []

    async def infer_handler(body: bytes) -> bytes:
        data = json.loads(body)
        pre = Receipt(
            user=data["receipt"]["user"],
            miner=data["receipt"]["miner"],
            brain_id=int(data["receipt"]["brain_id"]),
            prompt_hash=data["receipt"]["prompt_hash"],
            response_hash=data["receipt"]["response_hash"],
            amount=int(data["receipt"]["amount"]),
            expiry=int(data["receipt"]["expiry"]),
            nonce=int(data["receipt"]["nonce"]),
        )
        if pre.miner.lower() != miner.address.lower():
            return json.dumps({"error": "wrong miner"}).encode()
        if balances.get(pre.user.lower(), 0) < int(data["budget"]):
            return json.dumps({"error": "insufficient user balance"}).encode()
        if not verify_user_signature(MARKET, CHAIN_ID, pre, data["user_signature"]):
            return json.dumps({"error": "bad signature"}).encode()
        prompt = data["prompt"]
        if pre.prompt_hash.lower() != ("0x" + keccak(text=prompt).hex()).lower():
            return json.dumps({"error": "prompt hash mismatch"}).encode()
        response = f"devnet:{prompt}"
        response_hash = "0x" + keccak(text=response).hex()
        amount = min(
            PRICE_PER_REQUEST + PRICE_PER_BYTE * (len(prompt.encode()) + len(response.encode())),
            int(data["budget"]),
        )
        final = Receipt(
            user=pre.user,
            miner=pre.miner,
            brain_id=pre.brain_id,
            prompt_hash=pre.prompt_hash,
            response_hash=response_hash,
            amount=amount,
            expiry=pre.expiry,
            nonce=pre.nonce,
        )
        return json.dumps(
            {
                "text": response,
                "prompt_hash": pre.prompt_hash,
                "response_hash": response_hash,
                "tokens_in": len(prompt),
                "tokens_out": len(response),
                "final_receipt": _serialize(final),
                "miner_signature": "0x" + "55" * 65,
            }
        ).encode()

    async def settle_handler(body: bytes) -> bytes:
        data = json.loads(body)
        r = Receipt(
            user=data["receipt"]["user"],
            miner=data["receipt"]["miner"],
            brain_id=int(data["receipt"]["brain_id"]),
            prompt_hash=data["receipt"]["prompt_hash"],
            response_hash=data["receipt"]["response_hash"],
            amount=int(data["receipt"]["amount"]),
            expiry=int(data["receipt"]["expiry"]),
            nonce=int(data["receipt"]["nonce"]),
        )
        if not verify_user_signature(MARKET, CHAIN_ID, r, data["user_signature"]):
            return json.dumps({"error": "bad signature"}).encode()
        if balances.get(r.user.lower(), 0) < r.amount:
            return json.dumps({"error": "insufficient user balance"}).encode()
        balances[r.user.lower()] -= r.amount
        redeemed.append(r)
        settled.append(r)
        return json.dumps({"ok": True}).encode()

    async def challenge_handler(_: bytes) -> bytes:
        return json.dumps({"text": "challenge-ok", "response_hash": "0x" + "66" * 32}).encode()

    miner_client = await _started(make_miner_app(infer_handler, challenge_handler, settle_handler))
    miner_url = str(miner_client.make_url("/")).rstrip("/")

    idx = MemberIndex(endpoint_ttl_seconds=600)
    idx.apply_event("MinerRegistered", BRAIN_ID, miner.address)
    gateway_client = await _started(
        make_app(idx, now_fn=lambda: 1_700_000_000, url_guard=lambda _url: None)
    )

    try:
        # Failure path: unregistered miner cannot announce.
        other = Account.create()
        bad = {
            "address": other.address,
            "url": miner_url,
            "ts": 1_700_000_000,
            "signature": sign_announce(other, BRAIN_ID, miner_url, 1_700_000_000),
        }
        assert (await gateway_client.post(f"/brains/{BRAIN_ID}/announce", json=bad)).status == 403

        # Success path: registered miner announces and is discoverable.
        announce = {
            "address": miner.address,
            "url": miner_url,
            "ts": 1_700_000_000,
            "signature": sign_announce(miner, BRAIN_ID, miner_url, 1_700_000_000),
        }
        assert (await gateway_client.post(f"/brains/{BRAIN_ID}/announce", json=announce)).status == 200
        miners = await (await gateway_client.get(f"/brains/{BRAIN_ID}/miners")).json()
        assert miners and miners[0]["address"].lower() == miner.address.lower()

        prompt = "hello"
        budget = 10**15
        nonce = 42
        prompt_hash = "0x" + keccak(text=prompt).hex()
        sentinel = "0x" + Web3.keccak(hexstr=prompt_hash[2:] + format(nonce, "064x")).hex()
        preauth = Receipt(
            user=user.address,
            miner=miner.address,
            brain_id=BRAIN_ID,
            prompt_hash=prompt_hash,
            response_hash=sentinel,
            amount=10**12,
            expiry=int(time.time()) + 3600,
            nonce=nonce,
        )
        sig = _user_sig(user, preauth)
        infer = await gateway_client.post(
            f"/brains/{BRAIN_ID}/infer",
            json={
                "target_miner": miner.address,
                "prompt": prompt,
                "budget": budget,
                "receipt": _serialize(preauth),
                "user_signature": sig,
            },
        )
        assert infer.status == 200
        payload = await infer.json()
        assert payload["text"] == "devnet:hello"
        final = Receipt(
            user=payload["final_receipt"]["user"],
            miner=payload["final_receipt"]["miner"],
            brain_id=payload["final_receipt"]["brain_id"],
            prompt_hash=payload["final_receipt"]["prompt_hash"],
            response_hash=payload["final_receipt"]["response_hash"],
            amount=payload["final_receipt"]["amount"],
            expiry=payload["final_receipt"]["expiry"],
            nonce=payload["final_receipt"]["nonce"],
        )
        _assert_final_receipt_identity(preauth, final)
        expected_amount = PRICE_PER_REQUEST + PRICE_PER_BYTE * (len(prompt) + len(payload["text"]))
        assert final.amount == expected_amount
        settle = await gateway_client.post(
            f"/brains/{BRAIN_ID}/settle",
            json={"target_miner": miner.address, "receipt": _serialize(final), "user_signature": _user_sig(user, final)},
        )
        assert settle.status == 200
        assert settled and balances[user.address.lower()] == 10**18 - expected_amount

        # Failure path: tampered prompt hash is rejected before settlement.
        tampered = _serialize(preauth)
        tampered["prompt_hash"] = "0x" + "99" * 32
        bad_infer = await gateway_client.post(
            f"/brains/{BRAIN_ID}/infer",
            json={
                "target_miner": miner.address,
                "prompt": prompt,
                "budget": budget,
                "receipt": tampered,
                "user_signature": sig,
            },
        )
        assert (await bad_infer.json())["error"] in {"bad signature", "prompt hash mismatch"}

        # Aggregator success + failure paths, including restart/resubmission.
        stakes = {v1.address.lower(): 3000, v2.address.lower(): 3000}
        proposals: list[tuple[int, int, bytes, list[str], list[str]]] = []

        def _aggregator() -> tuple[TestClient, CommitmentAggregator]:
            agg = CommitmentAggregator(
                CHAIN_ID,
                SCORING,
                stake_of=lambda _brain, signer: stakes.get(signer.lower(), 0),
                total_stake=lambda _brain: 10_000,
                propose_fn=lambda e, b, r, s, sg: proposals.append((e, b, r, s, sg)) or "0xdevnet",
            )
            pool = CanonicalCandidatePool(
                lambda _brain, signer: stakes.get(signer.lower(), 0),
                lambda _brain: 10_000,
            )
            return make_aggregator_app(agg, pool, current_epoch_fn=lambda: 2), agg

        app, _ = _aggregator()
        agg_client = await _started(app)
        try:
            candidate_rows_1 = [{"miner": miner.address, "score": 100}]
            candidate_rows_2 = [{"miner": miner.address, "score": 300}]
            from basedai_validator.merkle import ScoreLeaf, build_merkle_root

            root1, _ = build_merkle_root([ScoreLeaf(BRAIN_ID, miner.address, 100)])
            sig1 = sign_commitment(v1, CHAIN_ID, SCORING, 1, BRAIN_ID, "0x" + root1.hex())
            r = await agg_client.post(
                "/candidates",
                json={
                    "epoch": 1,
                    "brain_id": BRAIN_ID,
                    "signer": v1.address,
                    "scores": candidate_rows_1,
                    "signature": sig1,
                },
            )
            assert r.status == 200 and (await r.json())["canonical"] is False

            root2, _ = build_merkle_root([ScoreLeaf(BRAIN_ID, miner.address, 300)])
            sig2 = sign_commitment(v2, CHAIN_ID, SCORING, 1, BRAIN_ID, "0x" + root2.hex())
            r = await agg_client.post(
                "/candidates",
                json={
                    "epoch": 1,
                    "brain_id": BRAIN_ID,
                    "signer": v2.address,
                    "scores": candidate_rows_2,
                    "signature": sig2,
                },
            )
            data = await r.json()
            assert r.status == 200 and data["canonical"] is True
            canonical_root = data["root"]

            forged = await agg_client.post(
                "/commitments",
                json={
                    "epoch": 1,
                    "brain_id": BRAIN_ID,
                    "root": canonical_root,
                    "signer": v2.address,
                    "signature": sign_commitment(v1, CHAIN_ID, SCORING, 1, BRAIN_ID, canonical_root),
                },
            )
            assert forged.status == 401

            for validator in (v1, v2):
                r = await agg_client.post(
                    "/commitments",
                    json={
                        "epoch": 1,
                        "brain_id": BRAIN_ID,
                        "root": canonical_root,
                        "signer": validator.address,
                        "signature": sign_commitment(validator, CHAIN_ID, SCORING, 1, BRAIN_ID, canonical_root),
                    },
                )
                assert r.status == 200
            assert proposals and proposals[0][0] == 1
        finally:
            await agg_client.close()

        # Restart recovery: gateway cursor state reconstructs canonical membership after process restart.
        with tempfile.TemporaryDirectory() as d:
            store = CursorStore(str(Path(d) / "cursor.json"))
            events = [{"name": "MinerRegistered", "brain_id": BRAIN_ID, "address": miner.address, "block_number": 1}]
            store.save_state(2, events, {"1": "0x" + "aa" * 32})
            recovered = MemberIndex()
            recovered.replace_membership(store.load_state()["events"])
            assert recovered.is_miner(BRAIN_ID, miner.address)

            # Simulated reorg removes the registration on restart; canonical rebuild must drop it.
            store.save_state(3, [], {"2": "0x" + "bb" * 32})
            recovered.replace_membership(store.load_state()["events"])
            assert not recovered.is_miner(BRAIN_ID, miner.address)

    finally:
        await gateway_client.close()
        await miner_client.close()


if __name__ == "__main__":
    asyncio.run(main())
    print("devnet e2e: ok")
