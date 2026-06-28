"""Tests for the membership/endpoint index and the announce protocol."""

from basedai_gateway.announce import recover_announce, sign_announce
from basedai_gateway.indexer import MemberIndex
from basedai_gateway.server import ChainPoller, CursorStore
from eth_account import Account


def test_cursor_store_roundtrip(tmp_path):
    store = CursorStore(str(tmp_path / "cursor.json"))
    assert store.load() is None  # first run: no cursor
    store.save(123)
    assert store.load() == 123
    store.save(456)
    assert store.load() == 456  # latest persisted value wins


class _FakeEth:
    def contract(self, address, abi):
        return object()


class _FakeW3:
    eth = _FakeEth()


def test_poller_resumes_from_durable_cursor(tmp_path):
    store = CursorStore(str(tmp_path / "c.json"))
    store.save(500)
    poller = ChainPoller(
        MemberIndex(), _FakeW3(), "0x" + "ab" * 20, start_block=0, cursor_store=store
    )
    # Resumes from the persisted cursor, NOT start_block=0 -> no rescan-from-genesis on restart.
    assert poller._next_block == 500


def test_membership_from_events():
    idx = MemberIndex()
    m = "0x" + "11" * 20
    idx.apply_event("MinerRegistered", 1, m)
    assert idx.is_miner(1, m)
    idx.apply_event("MinerDeregistered", 1, m)
    assert not idx.is_miner(1, m)


def test_canonical_rebuild_removes_orphaned_registration():
    idx = MemberIndex()
    m = "0x" + "11" * 20
    orphan = [{"name": "MinerRegistered", "brain_id": 1, "address": m}]
    idx.replace_membership(orphan)
    assert idx.is_miner(1, m)
    # Canonical replacement chain contains no registration event: a rebuild must remove it.
    idx.replace_membership([])
    assert not idx.is_miner(1, m)


def test_miners_requires_registration_and_announcement():
    idx = MemberIndex()
    m = "0x" + "11" * 20
    # Announced but not registered -> not listed.
    idx.announce(1, m, "https://miner.example", ts=100)
    assert idx.miners(1, now=100) == []
    # Registered + announced -> listed.
    idx.apply_event("MinerRegistered", 1, m)
    listed = idx.miners(1, now=100)
    assert len(listed) == 1 and listed[0]["url"] == "https://miner.example"


def test_stale_announcement_is_dropped():
    idx = MemberIndex(endpoint_ttl_seconds=600)
    m = "0x" + "11" * 20
    idx.apply_event("MinerRegistered", 1, m)
    idx.announce(1, m, "https://miner.example", ts=100)
    assert idx.miners(1, now=100 + 601) == []  # past TTL
    assert len(idx.miners(1, now=100 + 599)) == 1


def test_miners_sorted_by_score_desc():
    idx = MemberIndex()
    m1, m2 = "0x" + "11" * 20, "0x" + "22" * 20
    for m in (m1, m2):
        idx.apply_event("MinerRegistered", 1, m)
    idx.announce(1, m1, "https://a", ts=10, score=0.3)
    idx.announce(1, m2, "https://b", ts=10, score=0.9)
    listed = idx.miners(1, now=10)
    assert [m["url"] for m in listed] == ["https://b", "https://a"]


def test_deregister_drops_endpoint():
    idx = MemberIndex()
    m = "0x" + "11" * 20
    idx.apply_event("MinerRegistered", 1, m)
    idx.announce(1, m, "https://a", ts=10)
    idx.apply_event("MinerDeregistered", 1, m)
    assert idx.endpoint_of(1, m) is None


def test_announce_signature_roundtrip():
    acct = Account.create()
    sig = sign_announce(acct, 1, "https://miner.example", 12345)
    assert recover_announce(1, "https://miner.example", 12345, sig).lower() == acct.address.lower()
    # Tampered URL does not recover the signer.
    assert recover_announce(1, "https://evil.example", 12345, sig).lower() != acct.address.lower()
