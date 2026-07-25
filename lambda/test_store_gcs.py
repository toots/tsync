"""Tests for the GCS store backend against fake-gcs-server.

Needs a running emulator (CI starts one; locally:
    docker run -d -p 4443:4443 fsouza/fake-gcs-server -scheme http -public-host localhost:4443
). The one novel bit here is tiered `compose` — assembling more chunks than a
single compose call allows (COMPOSE_MAX) through temporary objects.

    pip install google-cloud-storage pytest
    STORAGE_EMULATOR_HOST=http://localhost:4443 pytest lambda/test_store_gcs.py
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

os.environ.setdefault("STORAGE_EMULATOR_HOST", "http://localhost:4443")
os.environ.setdefault("BUCKET", "tsync-test")
os.environ.setdefault("SHARES_PREFIX", "p/.shares/")

from google.cloud import storage  # noqa: E402

from share_common import ShareError  # noqa: E402
from store_gcs import COMPOSE_MAX, Store  # noqa: E402


@pytest.fixture
def store():
    # A project is only needed to create the bucket; object ops don't need one.
    admin = storage.Client(project="test")
    try:
        admin.create_bucket(os.environ["BUCKET"])
    except Exception:
        pass  # already exists
    for blob in admin.list_blobs(os.environ["BUCKET"]):
        blob.delete()  # clean slate between tests
    return Store()


def test_single_chunk(store):
    store.put_bytes("p/.chunks/a", b"AAAA")
    store.assemble(["p/.chunks/a"], "p/.shares/one.data")
    assert store.get_bytes("p/.shares/one.data") == b"AAAA"


def test_multi_chunk_one_compose(store):
    store.put_bytes("p/.chunks/a", b"AAAA")
    store.put_bytes("p/.chunks/b", b"BBBB")
    store.put_bytes("p/.chunks/c", b"CCCC")
    store.assemble(["p/.chunks/a", "p/.chunks/b", "p/.chunks/c"], "p/.shares/three.data")
    assert store.get_bytes("p/.shares/three.data") == b"AAAABBBBCCCC"


def test_tiered_compose_and_cleanup(store):
    # More than COMPOSE_MAX chunks forces tiering through temp objects.
    n = COMPOSE_MAX + 8
    keys = []
    for i in range(n):
        k = "p/.chunks/n%03d" % i
        store.put_bytes(k, ("%03d" % i).encode())
        keys.append(k)
    store.assemble(keys, "p/.shares/many.data")
    assert store.get_bytes("p/.shares/many.data") == b"".join(
        ("%03d" % i).encode() for i in range(n)
    )
    # Temp compose objects were cleaned up.
    assert list(store.list_keys("p/.shares/compose-tmp/")) == []


def test_missing_and_read(store):
    store.put_bytes("p/.chunks/a", b"AAAA")
    assert store.exists("p/.chunks/a")
    assert not store.exists("p/.chunks/nope")
    assert b"".join(store.read_chunk("p/.chunks/a")) == b"AAAA"
    with pytest.raises(FileNotFoundError):
        store.get_bytes("p/.chunks/nope")


def test_missing_source_raises(store):
    # Real GCS 404s a missing compose source -> ShareError 502; fake-gcs-server
    # returns a non-conformant 500, so assert only that it raises.
    store.put_bytes("p/.chunks/a", b"AAAA")
    with pytest.raises((ShareError, Exception)):
        store.assemble(["p/.chunks/a", "p/.chunks/missing"], "p/.shares/bad.data")
