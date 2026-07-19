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


def load_handler(max_bytes=10 * 1024**3):
    os.environ.update(
        BUCKET=BUCKET, SHARES_PREFIX="p/.shares/", PRESIGN_TTL="600",
        MAX_BYTES=str(max_bytes),
    )
    import handler

    return importlib.reload(handler)


def token_for(key):
    return base64.urlsafe_b64encode(key.encode()).rstrip(b"=").decode()


def event(token, sub="", query=None):
    path = "/" + token + (("/" + sub) if sub else "")
    return {"rawPath": path, "queryStringParameters": query or {}}


def put(s3, key, body):
    s3.put_object(Bucket=BUCKET, Key=key, Body=body)


def put_manifest(s3, key, chunks, mtime=1_700_000_000.0, symlink=None, size=None):
    # Distinct whole-file h1/h2 per key so per-file content-addressed caches differ.
    base = key.rsplit("/", 1)[-1]
    m = {"v": 1, "size": size if size is not None else sum(len(c[1]) for c in chunks),
         "chunkSize": 8 << 20, "h1": "f_" + base, "h2": "0", "mtime": mtime, "chunks": []}
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


def key_from_url(url):
    from urllib.parse import urlparse, unquote

    key = unquote(urlparse(url).path).lstrip("/")
    if key.startswith(BUCKET + "/"):  # path-style vs virtual-hosted
        key = key[len(BUCKET) + 1:]
    return key


def fetch_url(s3, url):
    return s3.get_object(Bucket=BUCKET, Key=key_from_url(url))["Body"].read()


def follow(s3, resp):
    """Given a 302, fetch the cached object the presigned URL points at."""
    assert resp["statusCode"] == 302
    key = key_from_url(resp["headers"]["Location"])
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
    # A folder share's /{token} is the browse page; the zip is at /{token}/download.
    body, _ = follow(s3, h.handler(event(tok, "download"), None))
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


def _folder_share(s3):
    put_manifest(s3, DOMAIN_PREFIX + "alb/cover.jpg", [("iiii-4444", b"\xff\xd8imgdata")])
    put_manifest(s3, DOMAIN_PREFIX + "alb/song.mp3", [("jjjj-5555", b"audiodata")])
    return share_manifest(s3, "sf", {
        "v": 1, "type": "zip", "chunkPrefix": CHUNK_PREFIX, "filename": "alb.zip",
        "expires": 9_999_999_999,
        "entries": [
            {"name": "cover.jpg", "key": DOMAIN_PREFIX + "alb/cover.jpg"},
            {"name": "song.mp3", "key": DOMAIN_PREFIX + "alb/song.mp3"},
        ],
    })


def test_browse_page(s3):
    h = load_handler()
    tok = _folder_share(s3)
    resp = h.handler(event(tok), None)
    assert resp["statusCode"] == 200
    assert "text/html" in resp["headers"]["Content-Type"]
    assert "cover.jpg" in resp["body"] and "song.mp3" in resp["body"]


def test_single_file_share_downloads(s3):
    # A file share's /{token} still redirects to the download (unchanged).
    h = load_handler()
    put_manifest(s3, DOMAIN_PREFIX + "one.txt", [("kkkk-6666", b"hi")])
    tok = share_manifest(s3, "sg", {
        "v": 1, "type": "file", "key": DOMAIN_PREFIX + "one.txt",
        "chunkPrefix": CHUNK_PREFIX, "filename": "one.txt", "expires": 9_999_999_999,
    })
    body, _ = follow(s3, h.handler(event(tok), None))
    assert body == b"hi"


def test_per_file_json_and_redirect(s3):
    h = load_handler()
    tok = _folder_share(s3)
    # JSON form: presigned URL + mime, and the bytes match.
    resp = h.handler(event(tok, "f/0", {"json": "1"}), None)
    assert resp["statusCode"] == 200
    doc = json.loads(resp["body"])
    assert doc["contentType"] == "image/jpeg"
    assert fetch_url(s3, doc["url"]) == b"\xff\xd8imgdata"
    cache_key = key_from_url(doc["url"])
    before = s3.head_object(Bucket=BUCKET, Key=cache_key)["LastModified"]
    # Redirect form of the same entry reuses the content-addressed cache.
    body, key2 = follow(s3, h.handler(event(tok, "f/0"), None))
    assert body == b"\xff\xd8imgdata" and key2 == cache_key
    after = s3.head_object(Bucket=BUCKET, Key=cache_key)["LastModified"]
    assert before == after
    # Second entry assembles to a different cache object.
    _, key_mp3 = follow(s3, h.handler(event(tok, "f/1"), None))
    assert key_mp3 != cache_key


def test_per_file_bad_index(s3):
    h = load_handler()
    tok = _folder_share(s3)
    assert h.handler(event(tok, "f/9"), None)["statusCode"] == 404


def test_max_bytes_file(s3):
    h = load_handler(max_bytes=100)
    put_manifest(s3, DOMAIN_PREFIX + "big.bin", [("llll-7777", b"x" * 500)], size=500)
    tok = share_manifest(s3, "sh", {
        "v": 1, "type": "file", "key": DOMAIN_PREFIX + "big.bin",
        "chunkPrefix": CHUNK_PREFIX, "filename": "big.bin", "expires": 9_999_999_999,
    })
    assert h.handler(event(tok, "download"), None)["statusCode"] == 413


def test_max_bytes_zip(s3):
    h = load_handler(max_bytes=100)
    put_manifest(s3, DOMAIN_PREFIX + "d/a", [("mmmm-8888", b"y" * 80)], size=80)
    put_manifest(s3, DOMAIN_PREFIX + "d/b", [("nnnn-9999", b"z" * 80)], size=80)
    tok = share_manifest(s3, "si", {
        "v": 1, "type": "zip", "chunkPrefix": CHUNK_PREFIX, "filename": "d.zip",
        "expires": 9_999_999_999,
        "entries": [
            {"name": "a", "key": DOMAIN_PREFIX + "d/a"},
            {"name": "b", "key": DOMAIN_PREFIX + "d/b"},
        ],
    })
    assert h.handler(event(tok, "download"), None)["statusCode"] == 413


def test_utf8_disposition_is_ascii(s3):
    # A name with an NFD accent + '&' must produce an ASCII Content-Disposition
    # (raw UTF-8 there makes S3 400); the accent goes in RFC 5987 filename*.
    from urllib.parse import urlparse, parse_qs
    h = load_handler()
    name = "Café & Co.mp3"  # NFD e + combining acute
    put_manifest(s3, DOMAIN_PREFIX + "x.mp3", [("pppp-0002", b"snd")])
    tok = share_manifest(s3, "sl", {
        "v": 1, "type": "zip", "chunkPrefix": CHUNK_PREFIX, "filename": "d.zip",
        "expires": 9_999_999_999,
        "entries": [{"name": name, "key": DOMAIN_PREFIX + "x.mp3"}],
    })
    resp = h.handler(event(tok, "f/0", {"json": "1"}), None)
    assert resp["statusCode"] == 200
    url = json.loads(resp["body"])["url"]
    disp = parse_qs(urlparse(url).query)["response-content-disposition"][0]
    disp.encode("ascii")  # must not raise
    assert "filename*=UTF-8''" in disp


def test_expired_on_subroute(s3):
    h = load_handler()
    tok = share_manifest(s3, "sj", {
        "v": 1, "type": "zip", "chunkPrefix": CHUNK_PREFIX, "filename": "x.zip",
        "expires": 1, "entries": [],
    })
    assert h.handler(event(tok, "download"), None)["statusCode"] == 410
