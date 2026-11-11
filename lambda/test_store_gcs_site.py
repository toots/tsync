"""The GCS store's sites bucket (http-proxy §A9.9, infrastructure/gcs.md §7),
against fake-gcs-server, started as for test_store_gcs.py:

    STORAGE_EMULATOR_HOST=http://localhost:4443 pytest lambda/test_store_gcs_site.py
"""

import os
import sys
from datetime import datetime, timezone

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

os.environ.setdefault("STORAGE_EMULATOR_HOST", "http://localhost:4443")
os.environ.setdefault("BUCKET", "tsync-test")
os.environ.setdefault("SHARES_PREFIX", "p/.shares/")
os.environ["SITES_BUCKET"] = "tsync-sites"

from google.cloud import storage  # noqa: E402

from store_gcs import Store  # noqa: E402


@pytest.fixture
def store():
    admin = storage.Client(project="test")
    for name in (os.environ["BUCKET"], os.environ["SITES_BUCKET"]):
        try:
            admin.create_bucket(name)
        except Exception:
            pass  # already exists
        for blob in admin.list_blobs(name):
            blob.delete()
    return Store()


def test_copy_into_the_sites_bucket(store):
    store.put_bytes("p/.shares/cache/x.data", b"<p>hi</p>")
    store.site_copy("p/.shares/cache/x.data", "tok/index.html", "text/html", 42, 1_900_000_000)
    assert store.site_get("tok/index.html") == b"<p>hi</p>"
    assert store.site_head("tok/index.html") == (9, "42")
    blob = store.sites.get_blob("tok/index.html")
    assert blob.content_type == "text/html"
    assert blob.cache_control == "no-cache"
    assert blob.custom_time == datetime.fromtimestamp(1_900_000_000, tz=timezone.utc)


def test_list_tokens_and_delete(store):
    store.put_bytes("p/.shares/cache/x.data", b"x")
    for key in ("t1/a.html", "t1/img/b.gif", "t2/a.html"):
        store.site_copy("p/.shares/cache/x.data", key, "text/html", 1, 1_900_000_000)
    assert sorted(store.site_tokens()) == ["t1", "t2"]
    assert sorted(store.site_keys("t1/")) == ["t1/a.html", "t1/img/b.gif"]
    store.site_delete(list(store.site_keys("t1/")))
    assert list(store.site_keys("t1/")) == []
    assert store.site_head("t1/a.html") is None
    with pytest.raises(FileNotFoundError):
        store.site_get("t1/a.html")


def test_site_url_is_the_bucket_endpoint(store):
    assert store.site_url("tok/été 1.htm") == (
        "https://tsync-sites.storage.googleapis.com/tok/%C3%A9t%C3%A9%201.htm"
    )
