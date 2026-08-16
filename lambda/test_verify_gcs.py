"""Chunk verifier against fake-gcs-server — the GCS half of test_verify.py.

Needs a running emulator (CI starts one; locally:
    docker run -d -p 4443:4443 fsouza/fake-gcs-server -scheme http -public-host localhost:4443
).

    pip install google-cloud-storage pytest xxhash
    STORAGE_EMULATOR_HOST=http://localhost:4443 pytest lambda/test_verify_gcs.py

The key-agreement question — does this compute the same name OCaml uploaded
under — is test_chunk_key.py's, and needs no cloud at all.
"""

import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

os.environ.setdefault("STORAGE_EMULATOR_HOST", "http://localhost:4443")
os.environ.setdefault("BUCKET", "tsync-test")
os.environ.setdefault("STORE", "gcs")

from google.cloud import storage  # noqa: E402

import verify  # noqa: E402
from store_gcs import Store  # noqa: E402


@pytest.fixture
def store():
    admin = storage.Client(project="test")
    try:
        admin.create_bucket(os.environ["BUCKET"])
    except Exception:
        pass  # already exists
    for blob in admin.list_blobs(os.environ["BUCKET"]):
        blob.delete()  # clean slate between tests
    return Store()


def chunk_path(domain, body):
    key = verify.key_of_body([body])
    return f"tsync/{domain}/chunks/{key[:3]}/{key}", key


def test_a_good_chunk_leaves_no_marker(store):
    body = b"hello world" * 100
    path, _ = chunk_path("d", body)
    store.put_bytes(path, body)

    assert verify.verify_object(store, path) is True
    assert list(store.list_keys("tsync/corrupted/d/")) == []


def test_a_scrambled_body_is_filed(store):
    body = b"hello world" * 100
    path, key = chunk_path("d", body)
    store.put_bytes(path, bytes(b ^ 0xFF for b in body))

    assert verify.verify_object(store, path) is False
    marker = f"tsync/corrupted/d/{key[:3]}/{key}"
    assert list(store.list_keys("tsync/corrupted/d/")) == [marker]
    recorded = json.loads(store.get_bytes(marker))
    assert recorded["computed"] != key
    assert recorded["computed"] == verify.key_of_body(
        [bytes(b ^ 0xFF for b in body)]
    )
    assert recorded["size"] == len(body)


def test_a_good_rewrite_clears_the_marker(store):
    """Nothing deletes a marker on purpose; it is cleared by the store
    re-verifying the object it was handed."""
    body = b"hello world" * 100
    path, _ = chunk_path("d", body)

    store.put_bytes(path, bytes(b ^ 0xFF for b in body))
    verify.verify_object(store, path)
    assert list(store.list_keys("tsync/corrupted/d/")) != []

    store.put_bytes(path, body)
    assert verify.verify_object(store, path) is True
    assert list(store.list_keys("tsync/corrupted/d/")) == []


def test_a_manifest_is_never_read(store):
    """A manifest is filed under the hash of its own file name, so it is spelled
    exactly like a chunk key: membership must be the prefix, not the shape."""
    key = verify.key_of_body([b"anything"])
    manifest_key = f"tsync/d/manifests/{key[:3]}/{key}"
    store.put_bytes(manifest_key, b"not a chunk body")

    assert verify.marker_key(manifest_key) is None
    assert verify.verify_object(store, manifest_key) is None
    assert list(store.list_keys("tsync/corrupted/d/")) == []


def test_delete_of_an_absent_marker_is_not_an_error(store):
    """The verifier clears before it looks, and most chunks never had one."""
    store.delete("tsync/corrupted/d/000/never-existed")


class _CloudEvent:
    def __init__(self, data):
        self.data = data


def test_the_pubsub_event_shape_is_decoded(store):
    """A storage notification arrives as a Pub/Sub message whose attributes
    carry objectId — not as an Eventarc storage event, which has no prefix
    filter and would fire on every write in the bucket."""
    body = b"hello world" * 100
    path, _ = chunk_path("d", body)
    store.put_bytes(path, bytes(b ^ 0xFF for b in body))

    verify._store = store
    event = _CloudEvent({"message": {"attributes": {"objectId": path}}})
    assert verify.gcp_verify(event) == {"checked": 1, "corrupt": 1}

    # A message with nothing to identify is ignored rather than raising, since a
    # raise would have the trigger redeliver it.
    assert verify.gcp_verify(_CloudEvent({"message": {}})) == {
        "checked": 0,
        "corrupt": 0,
        "deleted": 0,
    }


def test_the_background_calling_convention_works_too(store):
    """The other way the framework may call this: the message as a plain dict,
    with a second context argument.

    Which convention a deployment gets follows from a signature type nothing sets
    explicitly, and the wrong one is a TypeError on every single delivery — the
    function is invoked, raises before reading anything, and the sweep stands
    still with no marker to show for it. Called the one way only, this file
    passed while production could not check a single chunk.
    """
    body = b"hello world" * 100
    path, _ = chunk_path("d", body)
    store.put_bytes(path, bytes(b ^ 0xFF for b in body))

    verify._store = store
    message = {"attributes": {"objectId": path}, "data": ""}
    assert verify.gcp_verify(message, object()) == {"checked": 1, "corrupt": 1}

    assert verify.gcp_verify({"attributes": {}}, object()) == {
        "checked": 0,
        "corrupt": 0,
        "deleted": 0,
    }


def test_a_delete_request_drops_its_chunks_and_their_markers(store):
    """The GCS half of the delete path: the bulk delete is a thread pool here
    rather than one batched call, and swallowing NotFound is its own code."""
    doomed = b"garbage" * 100
    kept = b"still referenced" * 100
    doomed_path, doomed_key = chunk_path("d", doomed)
    kept_path, _ = chunk_path("d", kept)
    store.put_bytes(doomed_path, doomed)
    store.put_bytes(kept_path, kept)
    marker = f"tsync/corrupted/d/{doomed_key[:3]}/{doomed_key}"
    store.put_bytes(marker, b"{}")

    job = "tsync/gc-jobs/d/1755300000000/" + doomed_key[:3]
    store.put_bytes(job, doomed_path.encode())
    assert verify.verify_key(store, job)["deleted"] == 1

    assert not store.exists(doomed_path)
    assert not store.exists(marker)
    assert store.exists(kept_path)
    assert not store.exists(job)


def test_a_delete_request_may_not_name_another_domain(store):
    """The body is client-written and this function can delete any chunk in the
    bucket, so the check is against the requesting domain, not the key alone."""
    body = b"someone else's chunk" * 10
    theirs, _ = chunk_path("other", body)
    store.put_bytes(theirs, body)

    job = "tsync/gc-jobs/d/1755300000000/0ab"
    store.put_bytes(job, theirs.encode())
    assert verify.verify_key(store, job)["deleted"] == 0
    assert store.exists(theirs)


def test_delete_many_reports_nothing_for_keys_that_were_never_there():
    """Absent is a success: a resumed collection sends a batch it may already
    have deleted, and a redelivered request repeats itself."""
    st = Store()
    assert st.delete_many([]) == []
    assert st.delete_many(["tsync/d/chunks/000/nothing-here"]) == []


def test_delete_many_drops_every_key_it_is_given(store):
    """More keys than the pool is wide, so the threading is actually exercised
    rather than the one-key case standing in for it."""
    keys = []
    for i in range(40):
        key = f"tsync/d/chunks/{i % 16:03x}/bulk-{i}"
        store.put_bytes(key, b"x")
        keys.append(key)

    assert store.delete_many(keys) == []
    assert [k for k in keys if store.exists(k)] == []
