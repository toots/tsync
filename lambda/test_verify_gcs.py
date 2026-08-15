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
    }
