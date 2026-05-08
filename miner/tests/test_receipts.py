"""Tests for receipt signing and verification."""

import time

from eth_account import Account
from eth_account.messages import encode_defunct

from basedai_miner.receipts import Receipt, receipt_digest, verify_user_signature


MARKET = "0x" + "11" * 20
CHAIN_ID = 8453


def test_signature_round_trip():
    user = Account.create()
    miner = Account.create()

    r = Receipt(
        user=user.address,
        miner=miner.address,
        brain_id=8,
        prompt_hash="0x" + "a" * 64,
        response_hash="0x" + "b" * 64,
        amount=10**18,
        expiry=int(time.time()) + 3600,
        nonce=1,
    )

    digest = receipt_digest(MARKET, CHAIN_ID, r)
    msg = encode_defunct(digest)
    sig = user.sign_message(msg).signature.hex()

    assert verify_user_signature(MARKET, CHAIN_ID, r, sig)


def test_wrong_signer_rejected():
    user = Account.create()
    impostor = Account.create()
    miner = Account.create()

    r = Receipt(
        user=user.address,
        miner=miner.address,
        brain_id=8,
        prompt_hash="0x" + "a" * 64,
        response_hash="0x" + "b" * 64,
        amount=10**18,
        expiry=int(time.time()) + 3600,
        nonce=1,
    )

    digest = receipt_digest(MARKET, CHAIN_ID, r)
    msg = encode_defunct(digest)
    sig = impostor.sign_message(msg).signature.hex()

    assert not verify_user_signature(MARKET, CHAIN_ID, r, sig)
