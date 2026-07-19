"""Moto-backed tests for the share Lambda. Run manually:

    python3 -m venv .venv && . .venv/bin/activate
    pip install boto3 moto pytest
    pytest lambda/test_handler.py
"""

import importlib
import io
import json
import os
import zipfile

import boto3
import pytest
from moto import mock_aws

BUCKET = "tsync-test"
PREFIX = "p/.shares/"  # == SHARES_PREFIX; share manifest key is PREFIX + token
CHUNK_PREFIX = "p/.chunks/"
DOMAIN_PREFIX = "p/d/"


def load_handler(max_bytes=10 * 1024**3):
    os.environ.update(
        BUCKET=BUCKET, SHARES_PREFIX="p/.shares/", PRESIGN_TTL="600",
        MAX_BYTES=str(max_bytes),
    )
    import handler

    return importlib.reload(handler)


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
    # sid is a hex token; the manifest lives directly at PREFIX + token.
    key = PREFIX + sid
    put(s3, key, json.dumps(doc).encode())
    return sid


def dir_share(s3, sid, dir_prefix, filename="folder.zip"):
    return share_manifest(s3, sid, {
        "v": 1, "type": "dir", "chunkPrefix": CHUNK_PREFIX,
        "dirPrefix": dir_prefix, "filename": filename, "expires": 9_999_999_999,
    })


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
    assert resp["statusCode"] == 302, resp
    key = key_from_url(resp["headers"]["Location"])
    return s3.get_object(Bucket=BUCKET, Key=key)["Body"].read(), key


@pytest.fixture
def s3():
    with mock_aws():
        c = boto3.client("s3", region_name="us-east-1")
        c.create_bucket(Bucket=BUCKET)
        yield c


# ── File shares (unchanged model) ────────────────────────────────────────────


def test_multi_chunk_file(s3):
    h = load_handler()
    part0 = b"A" * (8 << 20)  # 8 MiB, satisfies multipart minimum
    part1 = b"B" * 1000
    put_manifest(s3, DOMAIN_PREFIX + "big.bin",
                 [("aaaa-0000", part0), ("bbbb-1111", part1)])
    tok = share_manifest(s3, "a1", {
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
    tok = share_manifest(s3, "a2", {
        "v": 1, "type": "file", "key": DOMAIN_PREFIX + "small.txt",
        "chunkPrefix": CHUNK_PREFIX, "filename": "small.txt",
        "expires": 9_999_999_999,
    })
    body, _ = follow(s3, h.handler(event(tok), None))
    assert body == b"hello"


def test_single_file_share_downloads(s3):
    # A file share's /{token} redirects straight to the download.
    h = load_handler()
    put_manifest(s3, DOMAIN_PREFIX + "one.txt", [("kkkk-6666", b"hi")])
    tok = share_manifest(s3, "a5", {
        "v": 1, "type": "file", "key": DOMAIN_PREFIX + "one.txt",
        "chunkPrefix": CHUNK_PREFIX, "filename": "one.txt", "expires": 9_999_999_999,
    })
    body, _ = follow(s3, h.handler(event(tok), None))
    assert body == b"hi"


def test_max_bytes_file(s3):
    h = load_handler(max_bytes=100)
    put_manifest(s3, DOMAIN_PREFIX + "big.bin", [("llll-7777", b"x" * 500)], size=500)
    tok = share_manifest(s3, "a6", {
        "v": 1, "type": "file", "key": DOMAIN_PREFIX + "big.bin",
        "chunkPrefix": CHUNK_PREFIX, "filename": "big.bin", "expires": 9_999_999_999,
    })
    assert h.handler(event(tok, "download"), None)["statusCode"] == 413


# ── Directory shares (live model) ────────────────────────────────────────────


def _folder_share(s3, sid="af"):
    put_manifest(s3, DOMAIN_PREFIX + "alb/cover.jpg", [("iiii-4444", b"\xff\xd8imgdata")])
    put_manifest(s3, DOMAIN_PREFIX + "alb/song.mp3", [("jjjj-5555", b"audiodata")])
    put_manifest(s3, DOMAIN_PREFIX + "alb/live/track.flac", [("kkkk-1234", b"livedata")])
    return dir_share(s3, sid, DOMAIN_PREFIX + "alb/", "alb.zip")


def test_browse_page(s3):
    # The page is lazy: it carries the title but not the (unlisted) entries.
    h = load_handler()
    tok = _folder_share(s3)
    resp = h.handler(event(tok), None)
    assert resp["statusCode"] == 200
    assert "text/html" in resp["headers"]["Content-Type"]
    assert "alb" in resp["body"]
    assert "cover.jpg" not in resp["body"]  # only fetched via /list


def test_dir_list_root_and_subdir(s3):
    h = load_handler()
    tok = _folder_share(s3)
    doc = json.loads(h.handler(event(tok, "list", {"path": ""}), None)["body"])
    assert doc["dirs"] == ["live"]
    names = [f["name"] for f in doc["files"]]
    assert names == ["cover.jpg", "song.mp3"]  # sorted
    sizes = {f["name"]: f["size"] for f in doc["files"]}
    assert sizes["cover.jpg"] == len(b"\xff\xd8imgdata")
    assert sizes["song.mp3"] == len(b"audiodata")
    # Navigate into the subdir.
    sub = json.loads(h.handler(event(tok, "list", {"path": "live"}), None)["body"])
    assert sub["dirs"] == []
    assert [f["name"] for f in sub["files"]] == ["track.flac"]


def test_dir_per_file_json_and_redirect(s3):
    h = load_handler()
    tok = _folder_share(s3)
    resp = h.handler(event(tok, "f", {"path": "cover.jpg", "json": "1"}), None)
    assert resp["statusCode"] == 200
    doc = json.loads(resp["body"])
    assert doc["contentType"] == "image/jpeg"
    assert fetch_url(s3, doc["url"]) == b"\xff\xd8imgdata"
    cache_key = key_from_url(doc["url"])
    before = s3.head_object(Bucket=BUCKET, Key=cache_key)["LastModified"]
    # Redirect form reuses the content-addressed cache.
    body, key2 = follow(s3, h.handler(event(tok, "f", {"path": "cover.jpg"}), None))
    assert body == b"\xff\xd8imgdata" and key2 == cache_key
    after = s3.head_object(Bucket=BUCKET, Key=cache_key)["LastModified"]
    assert before == after
    # A nested file resolves through its path.
    body, _ = follow(s3, h.handler(event(tok, "f", {"path": "live/track.flac"}), None))
    assert body == b"livedata"


def test_dir_missing_file(s3):
    h = load_handler()
    tok = _folder_share(s3)
    assert h.handler(event(tok, "f", {"path": "nope.txt"}), None)["statusCode"] == 404


def test_dir_path_traversal_rejected(s3):
    h = load_handler()
    tok = _folder_share(s3)
    assert h.handler(event(tok, "f", {"path": "../secret"}), None)["statusCode"] == 400
    assert h.handler(event(tok, "list", {"path": "a/../.."}), None)["statusCode"] == 400


def test_dir_download_zip(s3):
    h = load_handler()
    put_manifest(s3, DOMAIN_PREFIX + "d/a.txt", [("dddd-3333", b"aaa")])
    put_manifest(s3, DOMAIN_PREFIX + "d/sub/inner.txt", [("eeee-4444", b"in")])
    put_manifest(s3, DOMAIN_PREFIX + "d/link", [], symlink="a.txt")
    put(s3, DOMAIN_PREFIX + "d/empty/", b"")  # empty-dir marker
    put(s3, DOMAIN_PREFIX + "d/wip.txt", json.dumps({"dirty": True}).encode())
    tok = dir_share(s3, "a3", DOMAIN_PREFIX + "d/", "d.zip")
    body, _ = follow(s3, h.handler(event(tok, "download"), None))
    zf = zipfile.ZipFile(io.BytesIO(body))
    names = set(zf.namelist())
    # Entries are rooted under the folder name for a clean unzip.
    assert "d/a.txt" in names and "d/sub/inner.txt" in names
    assert "d/link" in names and "d/empty/" in names
    assert "d/wip.txt" not in names  # dirty skipped
    assert zf.read("d/a.txt") == b"aaa"
    assert zf.read("d/link") == b"a.txt"
    assert (zf.getinfo("d/link").external_attr >> 16) == 0xA1FF


def test_dir_download_cached(s3):
    h = load_handler()
    tok = _folder_share(s3)
    _, cache_key = follow(s3, h.handler(event(tok, "download"), None))
    before = s3.head_object(Bucket=BUCKET, Key=cache_key)["LastModified"]
    follow(s3, h.handler(event(tok, "download"), None))
    after = s3.head_object(Bucket=BUCKET, Key=cache_key)["LastModified"]
    assert before == after


def test_max_bytes_zip(s3):
    h = load_handler(max_bytes=100)
    put_manifest(s3, DOMAIN_PREFIX + "d2/a", [("mmmm-8888", b"y" * 80)], size=80)
    put_manifest(s3, DOMAIN_PREFIX + "d2/b", [("nnnn-9999", b"z" * 80)], size=80)
    tok = dir_share(s3, "a7", DOMAIN_PREFIX + "d2/", "d2.zip")
    assert h.handler(event(tok, "download"), None)["statusCode"] == 413


def test_encoded_key_roundtrip(s3):
    # A filename with reserved chars is stored under an encoded key; the browse
    # path is the decoded name, which the handler re-encodes to find it.
    h = load_handler()
    name = "a&b = c.txt"
    enc = h.encode_key(DOMAIN_PREFIX + "enc/" + name)
    put_manifest(s3, enc, [("qqqq-5678", b"payload")])
    tok = dir_share(s3, "ae", h.encode_key(DOMAIN_PREFIX + "enc/"), "enc.zip")
    doc = json.loads(h.handler(event(tok, "list", {"path": ""}), None)["body"])
    assert [f["name"] for f in doc["files"]] == [name]
    body, _ = follow(s3, h.handler(event(tok, "f", {"path": name}), None))
    assert body == b"payload"


def test_utf8_disposition_is_ascii(s3):
    # A name with an NFD accent + '&' must produce an ASCII Content-Disposition
    # (raw UTF-8 there makes S3 400); the accent goes in RFC 5987 filename*.
    from urllib.parse import urlparse, parse_qs
    h = load_handler()
    name = "Café & Co.mp3"  # NFD e + combining acute
    enc = h.encode_key(DOMAIN_PREFIX + "u/" + name)
    put_manifest(s3, enc, [("pppp-0002", b"snd")])
    tok = dir_share(s3, "a8", h.encode_key(DOMAIN_PREFIX + "u/"), "u.zip")
    resp = h.handler(event(tok, "f", {"path": name, "json": "1"}), None)
    assert resp["statusCode"] == 200
    url = json.loads(resp["body"])["url"]
    disp = parse_qs(urlparse(url).query)["response-content-disposition"][0]
    disp.encode("ascii")  # must not raise
    assert "filename*=UTF-8''" in disp


# ── Errors ───────────────────────────────────────────────────────────────────


def test_expired(s3):
    h = load_handler()
    tok = share_manifest(s3, "a4", {
        "v": 1, "type": "file", "key": DOMAIN_PREFIX + "x",
        "chunkPrefix": CHUNK_PREFIX, "filename": "x", "expires": 1,
    })
    assert h.handler(event(tok), None)["statusCode"] == 410


def test_expired_on_subroute(s3):
    h = load_handler()
    tok = dir_share(s3, "a9", DOMAIN_PREFIX + "gone/", "x.zip")
    s3.put_object(  # overwrite with an expired manifest
        Bucket=BUCKET, Key=PREFIX + "a9",
        Body=json.dumps({
            "v": 1, "type": "dir", "chunkPrefix": CHUNK_PREFIX,
            "dirPrefix": DOMAIN_PREFIX + "gone/", "filename": "x.zip", "expires": 1,
        }).encode(),
    )
    assert h.handler(event(tok, "list", {"path": ""}), None)["statusCode"] == 410


def test_unknown_id(s3):
    h = load_handler()
    # Well-formed hex id that was never written -> not found.
    assert h.handler(event("deadbeef"), None)["statusCode"] == 404


def test_garbage_token(s3):
    h = load_handler()
    # Non-hex tokens can't name a key under the prefix -> bad token.
    assert h.handler(event("secret"), None)["statusCode"] == 400
    assert h.handler({"rawPath": "/@@@@"}, None)["statusCode"] == 400
