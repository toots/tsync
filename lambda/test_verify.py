"""Moto-backed tests for the chunk verifier. Run manually:

    python3 -m venv .venv && . .venv/bin/activate
    pip install boto3 moto pytest xxhash
    pytest lambda/test_verify.py

That the key it computes agrees with OCaml's is a separate matter, and the more
important one: see test_chunk_key.py.
"""

import importlib
import json
import os

import boto3
import pytest
from moto import mock_aws

BUCKET = "tsync-test"


@pytest.fixture
def store_and_verify():
    with mock_aws():
        os.environ.update(BUCKET=BUCKET, STORE="aws")
        boto3.client("s3", region_name="us-east-1").create_bucket(Bucket=BUCKET)
        import store_aws
        import verify

        importlib.reload(store_aws)
        importlib.reload(verify)
        verify._store = None
        yield verify.store(), verify


def chunk_path(domain, body, verify):
    """Where a body belongs: named by its own hash, under its shard."""
    key = verify.key_of_body([body])
    return f"tsync/{domain}/chunks/{key[:3]}/{key}", key


def test_a_good_chunk_leaves_no_marker(store_and_verify):
    st, verify = store_and_verify
    body = b"hello world" * 100
    path, key = chunk_path("d", body, verify)
    st.put_bytes(path, body)

    assert verify.verify_object(st, path) is True
    assert list(st.list_keys("tsync/corrupted/d/")) == []


def test_a_scrambled_body_is_filed(store_and_verify):
    st, verify = store_and_verify
    body = b"hello world" * 100
    path, key = chunk_path("d", body, verify)
    # Same length, different bytes: what a size comparison cannot see.
    st.put_bytes(path, bytes(b ^ 0xFF for b in body))

    assert verify.verify_object(st, path) is False
    marker = f"tsync/corrupted/d/{key[:3]}/{key}"
    assert list(st.list_keys("tsync/corrupted/d/")) == [marker]

    recorded = json.loads(st.get_bytes(marker))
    assert recorded["computed"] != key
    assert recorded["computed"] == verify.key_of_body(
        [bytes(b ^ 0xFF for b in body)]
    )
    assert recorded["size"] == len(body)


def test_a_good_rewrite_clears_the_marker(store_and_verify):
    """The whole repair loop: nothing ever deletes a marker on purpose, it is
    cleared by the store re-verifying the object it was handed."""
    st, verify = store_and_verify
    body = b"hello world" * 100
    path, key = chunk_path("d", body, verify)

    st.put_bytes(path, bytes(b ^ 0xFF for b in body))
    verify.verify_object(st, path)
    assert list(st.list_keys("tsync/corrupted/d/")) != []

    st.put_bytes(path, body)
    assert verify.verify_object(st, path) is True
    assert list(st.list_keys("tsync/corrupted/d/")) == []


def test_a_manifest_is_never_read(store_and_verify):
    """A manifest is filed under the hash of its own file name, so it is spelled
    exactly like a chunk key. Deciding membership by the shape of the name rather
    than by the prefix would file every manifest in the bucket as corrupt."""
    st, verify = store_and_verify
    key = verify.key_of_body([b"anything"])
    manifest_key = f"tsync/d/manifests/{key[:3]}/{key}"
    st.put_bytes(manifest_key, b"not a chunk body")

    assert verify.marker_key(manifest_key) is None
    assert verify.verify_object(st, manifest_key) is None
    assert list(st.list_keys("tsync/corrupted/d/")) == []


def test_a_marker_never_earns_one_of_its_own(store_and_verify):
    """The non-recursion guard, held in code as well as in the notification's
    prefix filter: the function writes into the bucket it watches."""
    st, verify = store_and_verify
    key = verify.key_of_body([b"anything"])
    assert verify.marker_key(f"tsync/corrupted/d/{key[:3]}/{key}") is None
    # And a chunk in the space a collection is moving out of is left alone.
    assert verify.marker_key(f"tsync/d/chunks.from/{key[:3]}/{key}") is None


def test_domains_do_not_share_a_corrupted_prefix(store_and_verify):
    """One bucket can hold several domains, and the root is derived from the key
    rather than from an env var precisely so this works."""
    st, verify = store_and_verify
    body = b"x" * 500
    scrambled = b"y" * 500
    for domain in ("one", "two"):
        path, key = chunk_path(domain, body, verify)
        st.put_bytes(path, scrambled)
        verify.verify_object(st, path)
        assert list(st.list_keys(f"tsync/corrupted/{domain}/")) == [
            f"tsync/corrupted/{domain}/{key[:3]}/{key}"
        ]


def test_a_body_larger_than_one_read_slice(store_and_verify):
    """store_aws yields 1 MiB at a time, so anything bigger exercises the
    streamed hash rather than a one-shot one."""
    st, verify = store_and_verify
    body = bytes(((i * 31) + 7) & 0xFF for i in range(3 * 1024 * 1024))
    path, key = chunk_path("d", body, verify)
    st.put_bytes(path, body)

    assert verify.verify_object(st, path) is True
    assert list(st.list_keys("tsync/corrupted/d/")) == []


def test_the_aws_event_shape_is_decoded(store_and_verify):
    """S3 URL-encodes the key in the notification."""
    st, verify = store_and_verify
    body = b"hello world" * 100
    path, key = chunk_path("d", body, verify)
    st.put_bytes(path, bytes(b ^ 0xFF for b in body))

    event = {"Records": [{"s3": {"object": {"key": path.replace("/", "%2F")}}}]}
    assert verify.handler(event, None) == {"checked": 1, "corrupt": 1}


def test_a_job_sweeps_its_shard(store_and_verify):
    """The whole-store check: one request object per shard, delivered by the same
    notification, running the same per-chunk check."""
    st, verify = store_and_verify
    good = b"hello world" * 100
    bad = b"goodbye moon" * 100
    good_path, good_key = chunk_path("d", good, verify)
    bad_path, bad_key = chunk_path("d", bad, verify)
    st.put_bytes(good_path, good)
    st.put_bytes(bad_path, bytes(b ^ 0xFF for b in bad))
    # Both chunks land in the same shard only by luck, so drive each one's own.
    for key in (good_key, bad_key):
        job = f"tsync/verify-jobs/d/{key[:3]}"
        assert verify.job_target(job) == f"tsync/d/chunks/{key[:3]}/"
        st.put_bytes(job, b"")
        verify.verify_key(st, job)
        assert not st.exists(job)

    marked = list(st.list_keys("tsync/corrupted/d/"))
    assert marked == [f"tsync/corrupted/d/{bad_key[:3]}/{bad_key}"]


def test_a_job_for_an_empty_shard_is_just_dropped(store_and_verify):
    """Every shard is queued blind — an object store cannot cheaply say which
    prefixes are populated — so most requests find nothing and must cost
    nothing but their own deletion."""
    st, verify = store_and_verify
    job = "tsync/verify-jobs/d/fff"
    st.put_bytes(job, b"")
    assert verify.verify_key(st, job) == {"checked": 0, "corrupt": 0}
    assert not st.exists(job)
    assert list(st.list_keys("tsync/corrupted/d/")) == []


def test_a_request_never_looks_like_a_chunk(store_and_verify):
    """The two prefixes are told apart by the key alone, so neither entry point
    has to decide what it was handed."""
    st, verify = store_and_verify
    job = "tsync/verify-jobs/d/abc"
    assert verify.marker_key(job) is None
    key = verify.key_of_body([b"anything"])
    assert verify.job_target(f"tsync/d/chunks/{key[:3]}/{key}") is None
    assert verify.job_target("tsync/verify-jobs/d/not-a-shard") is None
    # A domain with a space in it, which is a real one.
    assert verify.job_target("tsync/verify-jobs/Jellyfin Media/abc") == "tsync/Jellyfin Media/chunks/abc/"


def gc_job(domain, run, shard):
    return f"tsync/gc-jobs/{domain}/{run}/{shard}"


def test_a_delete_request_drops_its_chunks_and_their_markers(store_and_verify):
    """What closing a collection hands over: the chunk keys alone, with the
    markers accusing them derived here rather than listed in the body."""
    st, verify = store_and_verify
    doomed = b"garbage" * 100
    kept = b"still referenced" * 100
    doomed_path, doomed_key = chunk_path("d", doomed, verify)
    kept_path, _ = chunk_path("d", kept, verify)
    st.put_bytes(doomed_path, doomed)
    st.put_bytes(kept_path, kept)
    marker = f"tsync/corrupted/d/{doomed_key[:3]}/{doomed_key}"
    st.put_bytes(marker, b"{}")

    job = gc_job("d", "1755300000000", doomed_key[:3])
    st.put_bytes(job, doomed_path.encode())
    assert verify.verify_key(st, job)["deleted"] == 1

    assert not st.exists(doomed_path)
    assert not st.exists(marker)
    assert st.exists(kept_path)
    # Deleted last, so a run that died partway would have left it behind.
    assert not st.exists(job)


def test_a_delete_request_may_not_name_another_domain(store_and_verify):
    """The body is the only thing choosing what this deletes, so it is checked
    against the requesting domain rather than trusted."""
    st, verify = store_and_verify
    body = b"someone else's chunk" * 10
    theirs, _ = chunk_path("other", body, verify)
    st.put_bytes(theirs, body)

    job = gc_job("d", "1755300000000", "0ab")
    st.put_bytes(job, theirs.encode())
    assert verify.verify_key(st, job)["deleted"] == 0
    assert st.exists(theirs)


def test_a_delete_request_may_name_only_chunks(store_and_verify):
    """A manifest is filed under the hash of its own name, so it is spelled
    exactly like a chunk key: membership is the prefix, never the shape."""
    st, verify = store_and_verify
    key = verify.key_of_body([b"anything"])
    off_limits = [
        f"tsync/d/manifests/{key[:3]}/{key}",
        f"tsync/d/chunks.from/{key[:3]}/{key}",
        f"tsync/corrupted/d/{key[:3]}/{key}",
        f"tsync/d/chunks/{key[:3]}/not-a-chunk-key",
        "tsync/d/journal",
    ]
    for path in off_limits:
        st.put_bytes(path, b"x")

    job = gc_job("d", "1755300000000", "0ab")
    st.put_bytes(job, "\n".join(off_limits).encode())
    assert verify.verify_key(st, job)["deleted"] == 0
    for path in off_limits:
        assert st.exists(path), path


def test_a_redelivered_delete_request_is_a_no_op(store_and_verify):
    """Object events are at-least-once, so the same request arrives twice and
    the second must not raise — a raise has S3 redeliver the whole batch."""
    st, verify = store_and_verify
    job = gc_job("d", "1755300000000", "0ab")
    st.put_bytes(job, b"")
    assert verify.verify_key(st, job)["deleted"] == 0
    assert not st.exists(job)
    assert verify.verify_key(st, job) == {"checked": 0, "corrupt": 0, "deleted": 0}


def test_a_delete_request_never_looks_like_anything_else(store_and_verify):
    """Three kinds of object reach one function, told apart by the key alone."""
    st, verify = store_and_verify
    key = verify.key_of_body([b"anything"])
    job = gc_job("d", "1755300000000", "0ab")
    assert verify.marker_key(job) is None
    assert verify.job_target(job) is None
    assert verify.gc_job_domain(f"tsync/d/chunks/{key[:3]}/{key}") is None
    assert verify.gc_job_domain("tsync/verify-jobs/d/0ab") is None
    # Without the run segment it is not one: a bare shard name would let a later
    # collection overwrite a request an earlier one left unconsumed.
    assert verify.gc_job_domain("tsync/gc-jobs/d/0ab") is None
    assert verify.gc_job_domain("tsync/gc-jobs/d/1755300000000/zz") is None
    assert verify.gc_job_domain(gc_job("Jellyfin Media", "1", "abc")) == "Jellyfin Media"
