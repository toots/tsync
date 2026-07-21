"""Moto-backed tests for the share Lambda. Run manually:

    python3 -m venv .venv && . .venv/bin/activate
    pip install boto3 moto pytest
    pytest lambda/test_handler.py

The Lambda navigates the inode layout by id — it lists a folder namespace
(manifests/<id>/…) and reads each child's body for its name/id/size — so these
fixtures don't need any hashing: a child's key can be any unique suffix under its
folder's namespace (here, a slug of its name).
"""

import hashlib
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
DOMAIN_PREFIX = "p/d/"  # manifests base; a folder's namespace is DOMAIN_PREFIX + <id> + "/"


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


def _slug(name):
    # A unique, key-safe child suffix; the value is opaque to the Lambda.
    return hashlib.sha1(name.encode()).hexdigest()[:16]


def _file_body(name, chunks, mtime=1_700_000_000.0, symlink=None, size=None):
    m = {"v": 1, "name": name,
         "size": size if size is not None else sum(len(c[1]) for c in chunks),
         "chunkSize": 8 << 20, "h1": "f_" + name, "h2": "0", "mtime": mtime,
         "chunks": []}
    for idx, (h, data) in enumerate(chunks):
        m["chunks"].append(
            {"index": idx, "h1": h.split("-")[0], "h2": h.split("-")[1],
             "size": len(data)})
    if symlink is not None:
        m["symlink"] = symlink
        m["chunks"] = []
    return m


def put_file(s3, folder_id, name, chunks, **kw):
    """Write a file's chunks and its manifest under [folder_id]'s namespace.
    Returns the manifest key (for a file share's "key")."""
    for h, data in chunks:
        put(s3, CHUNK_PREFIX + h, data)
    key = DOMAIN_PREFIX + folder_id + "/" + _slug(name)
    put(s3, key, json.dumps(_file_body(name, chunks, **kw)).encode())
    return key


def put_folder(s3, parent_id, name, child_id):
    """Write a folder marker naming [child_id] under [parent_id]'s namespace."""
    key = DOMAIN_PREFIX + parent_id + "/" + _slug(name)
    put(s3, key, json.dumps({"dir": True, "name": name, "id": child_id}).encode())
    return child_id


def put_dirty(s3, folder_id, name):
    put(s3, DOMAIN_PREFIX + folder_id + "/" + _slug(name),
        json.dumps({"v": 1, "name": name, "dirty": True}).encode())


def ns(folder_id):
    return DOMAIN_PREFIX + folder_id + "/"


def share_manifest(s3, sid, doc):
    # sid is a hex token; the manifest lives directly at PREFIX + token.
    put(s3, PREFIX + sid, json.dumps(doc).encode())
    return sid


def file_share(s3, sid, key, filename):
    return share_manifest(s3, sid, {
        "v": 1, "type": "file", "key": key, "chunkPrefix": CHUNK_PREFIX,
        "filename": filename, "expires": 9_999_999_999,
    })


def dir_share(s3, sid, dir_id, filename="folder.zip"):
    return share_manifest(s3, sid, {
        "v": 1, "type": "dir", "chunkPrefix": CHUNK_PREFIX,
        "dirPrefix": ns(dir_id), "filename": filename, "expires": 9_999_999_999,
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


# ── File shares ───────────────────────────────────────────────────────────────


def test_multi_chunk_file(s3):
    h = load_handler()
    part0 = b"A" * (8 << 20)  # 8 MiB, satisfies multipart minimum
    part1 = b"B" * 1000
    key = put_file(s3, "r", "big.bin",
                   [("aaaa-0000", part0), ("bbbb-1111", part1)])
    tok = file_share(s3, "a1", key, "big.bin")
    body, cache_key = follow(s3, h.handler(event(tok), None))
    assert body == part0 + part1
    # Second GET must not rebuild.
    before = s3.head_object(Bucket=BUCKET, Key=cache_key)["LastModified"]
    follow(s3, h.handler(event(tok), None))
    after = s3.head_object(Bucket=BUCKET, Key=cache_key)["LastModified"]
    assert before == after


def test_single_chunk_file(s3):
    h = load_handler()
    key = put_file(s3, "r", "small.txt", [("cccc-2222", b"hello")])
    tok = file_share(s3, "a2", key, "small.txt")
    body, _ = follow(s3, h.handler(event(tok), None))
    assert body == b"hello"


def test_single_file_share_downloads(s3):
    # A file share's /{token} redirects straight to the download.
    h = load_handler()
    key = put_file(s3, "r", "one.txt", [("kkkk-6666", b"hi")])
    tok = file_share(s3, "a5", key, "one.txt")
    body, _ = follow(s3, h.handler(event(tok), None))
    assert body == b"hi"


def test_max_bytes_file(s3):
    h = load_handler(max_bytes=100)
    key = put_file(s3, "r", "big.bin", [("llll-7777", b"x" * 500)], size=500)
    tok = file_share(s3, "a6", key, "big.bin")
    assert h.handler(event(tok, "download"), None)["statusCode"] == 413


# ── Directory shares ──────────────────────────────────────────────────────────


def _folder_share(s3, sid="af"):
    # alb/{cover.jpg, song.mp3, live/track.flac}
    put_file(s3, "alb", "cover.jpg", [("iiii-4444", b"\xff\xd8imgdata")])
    put_file(s3, "alb", "song.mp3", [("jjjj-5555", b"audiodata")])
    put_folder(s3, "alb", "live", "live")
    put_file(s3, "live", "track.flac", [("kkkk-1234", b"livedata")])
    return dir_share(s3, sid, "alb", "alb.zip")


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
    put_file(s3, "d", "a.txt", [("dddd-3333", b"aaa")])
    put_folder(s3, "d", "sub", "sub")
    put_file(s3, "sub", "inner.txt", [("eeee-4444", b"in")])
    put_file(s3, "d", "link", [], symlink="a.txt")
    put_folder(s3, "d", "empty", "empty")  # empty subfolder: marker, no children
    put_dirty(s3, "d", "wip.txt")  # mid-upload, must be skipped
    tok = dir_share(s3, "a3", "d", "d.zip")
    body, _ = follow(s3, h.handler(event(tok, "download"), None))
    zf = zipfile.ZipFile(io.BytesIO(body))
    names = set(zf.namelist())
    # Entries are rooted under the folder name for a clean unzip; empty dirs and
    # dirty files are not written.
    assert names == {"d/a.txt", "d/sub/inner.txt", "d/link"}
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
    put_file(s3, "d2", "a", [("mmmm-8888", b"y" * 80)], size=80)
    put_file(s3, "d2", "b", [("nnnn-9999", b"z" * 80)], size=80)
    tok = dir_share(s3, "a7", "d2", "d2.zip")
    assert h.handler(event(tok, "download"), None)["statusCode"] == 413


def test_reserved_char_name(s3):
    # Names live in the manifest body, so reserved chars need no encoding: the
    # browse lists the raw name and serves it by matching that name.
    h = load_handler()
    name = "a&b = c.txt"
    put_file(s3, "enc", name, [("qqqq-5678", b"payload")])
    tok = dir_share(s3, "ae", "enc", "enc.zip")
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
    put_file(s3, "u", name, [("pppp-0002", b"snd")])
    tok = dir_share(s3, "a8", "u", "u.zip")
    resp = h.handler(event(tok, "f", {"path": name, "json": "1"}), None)
    assert resp["statusCode"] == 200
    url = json.loads(resp["body"])["url"]
    disp = parse_qs(urlparse(url).query)["response-content-disposition"][0]
    disp.encode("ascii")  # must not raise
    assert "filename*=UTF-8''" in disp


# ── Errors ───────────────────────────────────────────────────────────────────


def test_expired(s3):
    h = load_handler()
    tok = file_share(s3, "a4", DOMAIN_PREFIX + "r/x", "x")
    s3.put_object(  # overwrite with an expired manifest
        Bucket=BUCKET, Key=PREFIX + "a4",
        Body=json.dumps({
            "v": 1, "type": "file", "key": DOMAIN_PREFIX + "r/x",
            "chunkPrefix": CHUNK_PREFIX, "filename": "x", "expires": 1,
        }).encode(),
    )
    assert h.handler(event(tok), None)["statusCode"] == 410


def test_expired_on_subroute(s3):
    h = load_handler()
    tok = dir_share(s3, "a9", "gone", "x.zip")
    s3.put_object(  # overwrite with an expired manifest
        Bucket=BUCKET, Key=PREFIX + "a9",
        Body=json.dumps({
            "v": 1, "type": "dir", "chunkPrefix": CHUNK_PREFIX,
            "dirPrefix": ns("gone"), "filename": "x.zip", "expires": 1,
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
