"""Moto-backed tests for the share Lambda. Run manually:

    python3 -m venv .venv && . .venv/bin/activate
    pip install boto3 moto pytest
    pytest terraform/lambda/test_handler.py
"""

import base64
import importlib
import io
import json
import os
import zipfile

import boto3
import pytest
from moto import mock_aws

BUCKET = "tsync-test"
PREFIX = "p/.shares/d/"  # encoded "<prefix>/.shares/<domain>/"
CHUNK_PREFIX = "p/.chunks/"
DOMAIN_PREFIX = "p/d/"


def load_handler():
    os.environ.update(BUCKET=BUCKET, SHARES_PREFIX="p/.shares/", PRESIGN_TTL="600")
    import handler

    return importlib.reload(handler)


def token_for(key):
    return base64.urlsafe_b64encode(key.encode()).rstrip(b"=").decode()


def event(token):
    return {"rawPath": "/" + token}


def put(s3, key, body):
    s3.put_object(Bucket=BUCKET, Key=key, Body=body)


def put_manifest(s3, key, chunks, mtime=1_700_000_000.0, symlink=None):
    m = {"v": 1, "size": sum(len(c[1]) for c in chunks), "chunkSize": 8 << 20,
         "h1": "x", "h2": "y", "mtime": mtime, "chunks": []}
    for idx, (h, data) in enumerate(chunks):
        put(s3, CHUNK_PREFIX + h, data)
        m["chunks"].append({"index": idx, "h1": h.split("-")[0], "h2": h.split("-")[1], "size": len(data)})
    if symlink is not None:
        m["symlink"] = symlink
        m["chunks"] = []
    put(s3, key, json.dumps(m).encode())


def share_manifest(s3, sid, doc):
    key = PREFIX + sid
    put(s3, key, json.dumps(doc).encode())
    return token_for(key)


def follow(s3, resp):
    """Given a 302, fetch the cached object the presigned URL points at."""
    assert resp["statusCode"] == 302
    # Parse the object key back out of the presigned URL path (moto-friendly).
    from urllib.parse import urlparse, unquote

    key = unquote(urlparse(resp["headers"]["Location"]).path).lstrip("/")
    if key.startswith(BUCKET + "/"):  # path-style vs virtual-hosted
        key = key[len(BUCKET) + 1:]
    return s3.get_object(Bucket=BUCKET, Key=key)["Body"].read(), key


@pytest.fixture
def s3():
    with mock_aws():
        c = boto3.client("s3", region_name="us-east-1")
        c.create_bucket(Bucket=BUCKET)
        yield c


def test_multi_chunk_file(s3):
    h = load_handler()
    part0 = b"A" * (8 << 20)  # 8 MiB, satisfies multipart minimum
    part1 = b"B" * 1000
    put_manifest(s3, DOMAIN_PREFIX + "big.bin",
                 [("aaaa-0000", part0), ("bbbb-1111", part1)])
    tok = share_manifest(s3, "s1", {
        "v": 1, "type": "file", "key": DOMAIN_PREFIX + "big.bin",
        "chunkPrefix": CHUNK_PREFIX, "filename": "big.bin",
        "expires": 9_999_999_999,
    })
    body, cache_key = follow(s3, h.handler(event(tok), None))
    assert body == part0 + part1
    # Second GET must not rebuild.
    before = s3.head_object(Bucket=BUCKET, Key=cache_key)["LastModified"]
    follow(s3, h.handler(event(tok), None))
    after = s3.head_object(Bucket=BUCKET, Key=cache_key)["LastModified"]
    assert before == after


def test_single_chunk_file(s3):
    h = load_handler()
    put_manifest(s3, DOMAIN_PREFIX + "small.txt", [("cccc-2222", b"hello")])
    tok = share_manifest(s3, "s2", {
        "v": 1, "type": "file", "key": DOMAIN_PREFIX + "small.txt",
        "chunkPrefix": CHUNK_PREFIX, "filename": "small.txt",
        "expires": 9_999_999_999,
    })
    body, _ = follow(s3, h.handler(event(tok), None))
    assert body == b"hello"


def test_zip_folder(s3):
    h = load_handler()
    put_manifest(s3, DOMAIN_PREFIX + "dir/a.txt", [("dddd-3333", b"aaa")])
    put_manifest(s3, DOMAIN_PREFIX + "dir/link", [], symlink="a.txt")
    put(s3, DOMAIN_PREFIX + "dir/empty/", b"")  # dir marker
    # A dirty entry that must be skipped.
    put(s3, DOMAIN_PREFIX + "dir/wip.txt", json.dumps({"dirty": True}).encode())
    tok = share_manifest(s3, "s3", {
        "v": 1, "type": "zip", "chunkPrefix": CHUNK_PREFIX, "filename": "dir.zip",
        "expires": 9_999_999_999,
        "entries": [
            {"name": "a.txt", "key": DOMAIN_PREFIX + "dir/a.txt"},
            {"name": "link", "key": DOMAIN_PREFIX + "dir/link"},
            {"name": "empty/"},
            {"name": "wip.txt", "key": DOMAIN_PREFIX + "dir/wip.txt"},
        ],
    })
    body, _ = follow(s3, h.handler(event(tok), None))
    zf = zipfile.ZipFile(io.BytesIO(body))
    names = set(zf.namelist())
    assert "a.txt" in names and "empty/" in names and "link" in names
    assert "wip.txt" not in names  # dirty skipped
    assert zf.read("a.txt") == b"aaa"
    assert zf.read("link") == b"a.txt"
    link_info = zf.getinfo("link")
    assert (link_info.external_attr >> 16) == 0xA1FF


def test_expired(s3):
    h = load_handler()
    tok = share_manifest(s3, "s4", {
        "v": 1, "type": "file", "key": DOMAIN_PREFIX + "x",
        "chunkPrefix": CHUNK_PREFIX, "filename": "x", "expires": 1,
    })
    assert h.handler(event(tok), None)["statusCode"] == 410


def test_unknown_id(s3):
    h = load_handler()
    tok = token_for(PREFIX + "doesnotexist")
    assert h.handler(event(tok), None)["statusCode"] == 404


def test_garbage_token(s3):
    h = load_handler()
    # Valid base64 but points outside the shares prefix -> forbidden.
    assert h.handler(event(token_for("p/d/secret")), None)["statusCode"] == 403
    # Not decodable -> bad token.
    assert h.handler({"rawPath": "/@@@@"}, None)["statusCode"] in (400, 403)
