"""tsync share Lambda.

Serves shared files/folders from the tsync S3 chunk store. A request path is
``/{token}[/sub]`` where ``token`` is the random hex id of a *share manifest*
(written by ``tsync share``); the full S3 key is ``SHARES_PREFIX + token``. Routes:

- ``/{token}``            dir share -> HTML file browser; file share -> download
- ``/{token}/download``   assemble the whole artifact (file, or dir as a zip)
- ``/{token}/list?path=`` (dir) one directory level as JSON: subdirs + files+sizes
- ``/{token}/f?path=``    (dir) assemble one file; 302 to a presigned GET
                          (``?json=1`` returns the URL as JSON for inline media
                          preview, ``?dl=1`` forces an attachment download)

A dir share stores only the directory's key prefix; the browser lists one folder
at a time via ``/list``, so ``tsync share`` and page load stay O(1) regardless of
how many files the directory holds. Assembled artifacts are cached under
``SHARES_PREFIX + "cache/"`` and served via a short-lived presigned GET (responses
are size-capped, so we never stream bodies ourselves). Everything in that subtree
is rebuildable, which is what makes ``tsync clear-share-cache`` safe.

Size guard: a single file (or per-file preview) and the running total of a folder
zip are both capped at MAX_BYTES (default 10 GiB) -> 413, so a build can't blow
past the /tmp ephemeral disk or run for the full 900 s timeout. The multipart
path also caps a single file at ~80 GB (10,000 parts). Upgrade path when these
bite: build on Fargate.
"""

import html
import json
import os
import time
import traceback
import zipfile

import manifest
from share_common import ShareError, cache_prefix

SHARES_PREFIX = os.environ.get("SHARES_PREFIX", "tsync/shares/")  # guard: keys must start with this
# A token is hex, so nothing published can ever land in here.
CACHE_PREFIX = cache_prefix(SHARES_PREFIX)
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(10 * 1024**3)))

# Pick the storage backend by env; import lazily so one deployment zip runs on
# either cloud without importing the other's SDK.
if os.environ.get("STORE", "aws") == "gcs":
    from store_gcs import Store
else:
    from store_aws import Store

store = Store()


def too_large():
    return ShareError(413, "too large to assemble (limit %d bytes)" % MAX_BYTES)


# ── S3 helpers ──────────────────────────────────────────────────────────────


def get_bytes(key):
    return store.get_bytes(key)


def get_json(key):
    return json.loads(get_bytes(key))


def object_exists(key):
    return store.exists(key)


# Chunk keys are fixed-length hex; the store shards them by their first
# CHUNK_FANOUT characters. Must match lib/naming/chunk_layout.ml.
CHUNK_FANOUT = 3


def chunk_key(chunk_prefix, key):
    shard = key[:CHUNK_FANOUT] if len(key) >= CHUNK_FANOUT else "_"
    return f"{chunk_prefix}{shard}/{key}"


# ── Inode navigation ────────────────────────────────────────────────────────
#
# Folders are identified by a stable id, not their name: a folder's children
# live flat under manifests/<id>/<hash>, each object being either a file manifest
# (body has "name", "chunks", "size") or a folder marker (body {dir,name,id}).
# Names live in the bodies, so the Lambda never hashes — it lists a namespace and
# reads each child. A dir share stores the folder's namespace prefix (dirPrefix =
# <...>/manifests/<id>/); resync/tsync never expose the .tsync-trash namespace.


def ns_base(dir_prefix):
    # <...>/manifests/<id>/  ->  <...>/manifests/
    return dir_prefix.rstrip("/").rsplit("/", 1)[0] + "/"


def child_objects(ns_prefix):
    """Direct children of a folder namespace as (name, key, is_dir, size).
    For a subdir, key is its own namespace prefix; for a file, its manifest key.
    One GET per child to read names/ids/sizes from bodies (folders are small)."""
    base = ns_base(ns_prefix)
    out = []
    for key in store.list_keys(ns_prefix):
        if key == ns_prefix:
            continue
        try:
            body = get_bytes(key)
        except FileNotFoundError:
            continue
        # A file manifest and a folder marker share this namespace and are told
        # apart by the body: the first is binary and starts with the magic, the
        # second is JSON.
        if manifest.is_manifest(body):
            try:
                m = manifest.Manifest(body)
            except manifest.Malformed:
                continue
            out.append((m.name, key, False, m.size))
            continue
        try:
            m = json.loads(body)
        except ValueError:
            continue
        if m.get("dir"):
            out.append((m.get("name", ""), base + m["id"] + "/", True, None))
    return out


def resolve(dir_prefix, rel):
    """Walk [rel] (decoded, '/'-separated) from the shared folder by matching
    names. Returns ('dir', namespace_prefix) or ('file', manifest_key), else
    None."""
    kind, loc = "dir", dir_prefix
    for part in [p for p in rel.split("/") if p]:
        if kind != "dir":
            return None
        match = next((c for c in child_objects(loc) if c[0] == part), None)
        if match is None:
            return None
        _, key, is_dir, _ = match
        kind, loc = ("dir" if is_dir else "file"), key
    return (kind, loc)


def safe_rel(path):
    """A browse-supplied path (decoded, '/'-separated) under the shared dir.
    Reject anything that could escape the prefix."""
    parts = [p for p in (path or "").split("/") if p]
    if any(p in (".", "..") for p in parts):
        raise ShareError(400, "bad path")
    return "/".join(parts)


# ── Assembly ────────────────────────────────────────────────────────────────


def file_manifest(key):
    """Load a file manifest, rejecting folder markers and symlinks with a clean
    error."""
    try:
        body = get_bytes(key)
    except FileNotFoundError:
        raise ShareError(404, "file not found")
    if not manifest.is_manifest(body):
        raise ShareError(400, "this share points at a folder, not a file")
    try:
        m = manifest.Manifest(body)
    except manifest.Malformed as e:
        raise ShareError(502, "unreadable manifest: %s" % e)
    if m.symlink is not None:
        raise ShareError(400, "cannot serve a symlink directly")
    return m


def assemble(m, chunk_prefix, cache_key):
    """Write a file's bytes to cache_key by server-side chunk assembly (no /tmp).
    Applies the size / count guards, then hands the ordered chunk keys to the
    store, which stitches them (S3 multipart-copy / GCS compose)."""
    if m.size > MAX_BYTES:
        raise too_large()
    if m.count == 0:
        store.put_bytes(cache_key, b"")
        return
    if m.count > 10000:
        raise too_large()
    store.assemble([chunk_key(chunk_prefix, k) for k in m.keys()], cache_key)


def build_file(file_key, chunk_prefix, cache_key):
    assemble(file_manifest(file_key), chunk_prefix, cache_key)


def mtime_tuple(mtime):
    try:
        t = time.localtime(mtime)
        if t.tm_year < 1980:
            return (1980, 1, 1, 0, 0, 0)
        return t[:6]
    except Exception:
        return (1980, 1, 1, 0, 0, 0)


def write_zip(entries, chunk_prefix, cache_key):
    """Stream (name, file_manifest_key | None) pairs into a zip at cache_key.
    A None key is a directory marker. Missing/dirty files are skipped."""
    tmp = "/tmp/" + os.path.basename(cache_key)
    total = 0
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED, allowZip64=True) as zf:
            for name, key in entries:
                if key is None:
                    marker = name if name.endswith("/") else name + "/"
                    zf.writestr(zipfile.ZipInfo(marker), b"")
                    continue
                try:
                    m = manifest.Manifest(get_bytes(key))
                except FileNotFoundError:
                    continue  # deleted between listing and build
                except manifest.Malformed:
                    continue
                total += m.size
                if total > MAX_BYTES:
                    raise too_large()
                zi = zipfile.ZipInfo(name, date_time=mtime_tuple(m.mtime))
                if m.symlink is not None:
                    zi.external_attr = 0xA1FF << 16  # S_IFLNK | 0777
                    zf.writestr(zi, m.symlink.encode())
                    continue
                zi.compress_type = zipfile.ZIP_STORED
                with zf.open(zi, "w") as w:
                    for k in m.keys():
                        for buf in store.read_chunk(chunk_key(chunk_prefix, k)):
                            w.write(buf)
        store.upload_file(tmp, cache_key)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def iter_dir_entries(dir_prefix, root):
    """Recursively enumerate a shared directory by walking the inode tree,
    yielding (zip_name, file_manifest_key). Names are rooted under [root] so
    unzip creates a single top folder."""

    def walk(ns, prefix):
        for name, key, is_dir, _ in child_objects(ns):
            zip_name = prefix + "/" + name
            if is_dir:
                yield from walk(key, zip_name)
            else:
                yield zip_name, key

    yield from walk(dir_prefix, root)


def build_dir_zip(share, cache_key):
    root = share.get("filename", "share")
    if root.endswith(".zip"):
        root = root[:-4]
    write_zip(
        iter_dir_entries(share["dirPrefix"], root), share["chunkPrefix"], cache_key
    )


# ── Content types ───────────────────────────────────────────────────────────

# Extension -> MIME type. Shared with the OCaml http-proxy share server, which
# embeds this same file at build time, so the table has one definition.
with open(os.path.join(os.path.dirname(__file__), "mime.json")) as _f:
    MIME = json.load(_f)


def mime_type(name):
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    return MIME.get(ext)


def preview_kind(mime):
    """How browse.html should preview a file with this MIME type."""
    mime = mime.split(";", 1)[0].strip()
    if mime.startswith("image/"):
        return "image"
    if mime.startswith("audio/"):
        return "audio"
    if mime.startswith("video/"):
        return "video"
    if mime == "application/pdf":
        return "pdf"
    if mime == "text/html":
        return "html"
    return "text"  # text/plain, application/json, application/xml


# ext -> preview kind, injected into browse.html so the front end has no
# duplicated extension lists to keep in sync with MIME.
PREVIEW_KINDS = {ext: preview_kind(m) for ext, m in MIME.items()}


# ── Responses ───────────────────────────────────────────────────────────────


def err(code, msg):
    return {"statusCode": code, "headers": {"Content-Type": "text/plain"}, "body": msg + "\n"}


def redirect(url):
    return {"statusCode": 302, "headers": {"Location": url}}


def json_response(obj):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(obj),
    }


def html_response(body):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": body,
    }


# ── Routing ─────────────────────────────────────────────────────────────────


def load_share(token):
    # The token is the manifest's random hex id; the key lives under our own
    # prefix, so a hex-only token can never point outside it.
    if not token or any(c not in "0123456789abcdef" for c in token):
        raise ShareError(400, "bad token")
    manifest_key = SHARES_PREFIX + token
    try:
        share = get_json(manifest_key)
    except FileNotFoundError:
        raise ShareError(404, "not found")
    if time.time() > share.get("expires", 0):
        raise ShareError(410, "link expired")
    return share


def download_artifact(token, share):
    # The whole artifact (a file's bytes, or a directory zipped) is cached under
    # CACHE_PREFIX and served presigned. For a dir this freezes the zip at
    # first-download time; fine given the short share TTL.
    cache_key = CACHE_PREFIX + token + ".data"
    if not object_exists(cache_key):
        if share["type"] == "file":
            build_file(share["key"], share["chunkPrefix"], cache_key)
        elif share["type"] == "dir":
            build_dir_zip(share, cache_key)
        else:
            raise ShareError(400, "unknown share type")
    return redirect(store.signed_url(cache_key, share["filename"], inline=False))


def list_dir(share, rel):
    """One directory level under the share: (subdir names, [(name, size)]).
    ponytail: one GET per child to read names/sizes from bodies — fine for normal
    folders; a folder with thousands of direct children pays that many GETs."""
    ns = share["dirPrefix"]
    if rel:
        r = resolve(ns, rel)
        if not r or r[0] != "dir":
            raise ShareError(404, "not found")
        ns = r[1]
    dirs, files = [], []
    for name, _key, is_dir, size in child_objects(ns):
        if is_dir:
            dirs.append(name)
        else:
            files.append((name, size))
    return dirs, files


def list_response(share, path):
    dirs, files = list_dir(share, safe_rel(path))
    return json_response(
        {
            "dirs": sorted(dirs, key=str.lower),
            "files": [
                {"name": n, "size": s}
                for n, s in sorted(files, key=lambda f: f[0].lower())
            ],
        }
    )


def serve_file(share, path, as_download, want_json):
    rel = safe_rel(path)
    if not rel:
        raise ShareError(400, "not a file")
    r = resolve(share["dirPrefix"], rel)
    if not r or r[0] != "file":
        raise ShareError(404, "file not found")
    m = file_manifest(r[1])
    cache_key = CACHE_PREFIX + m.h1 + "-" + m.h2 + ".data"
    if not object_exists(cache_key):
        assemble(m, share["chunkPrefix"], cache_key)
    name = os.path.basename(rel)
    ctype = mime_type(name)
    url = store.signed_url(cache_key, name, content_type=ctype, inline=not as_download)
    if want_json:
        return json_response(
            {"url": url, "name": name, "contentType": ctype, "size": m.size}
        )
    return redirect(url)


def handler(event, context):
    try:
        parts = event.get("rawPath", "/").strip("/").split("/")
        token = parts[0] if parts else ""
        sub = parts[1] if len(parts) > 1 else ""
        if not token:
            raise ShareError(400, "missing token")
        share = load_share(token)
        q = event.get("queryStringParameters") or {}
        is_dir = share.get("type") == "dir"
        if sub == "":
            if is_dir:
                return html_response(render_browse(share, token))
            return download_artifact(token, share)
        if sub == "download":
            return download_artifact(token, share)
        if is_dir and sub == "list":
            return list_response(share, q.get("path", ""))
        if is_dir and sub == "f":
            return serve_file(
                share, q.get("path", ""),
                as_download=q.get("dl") == "1", want_json=q.get("json") == "1",
            )
        raise ShareError(404, "not found")
    except ShareError as e:
        return err(e.code, e.msg)
    except Exception as e:
        # Anything else is a bug or an unexpected backend state: log the full
        # traceback to CloudWatch and return a 500 that at least names the cause
        # rather than a bare "Internal Server Error".
        traceback.print_exc()
        return err(500, "internal error (%s)" % type(e).__name__)


def gcp_handler(request):
    """Cloud Functions (functions-framework) entry point. Adapts a Flask request
    to the event dict the core handler consumes, and its response dict back to a
    Flask (body, status, headers) tuple. The core [handler] stays AWS-shaped so
    the moto tests exercise it directly."""
    event = {"rawPath": request.path, "queryStringParameters": dict(request.args)}
    resp = handler(event, None)
    return (resp.get("body", ""), resp["statusCode"], resp.get("headers", {}))


def render_browse(share, token):
    title = share.get("filename", "share")
    if title.endswith(".zip"):
        title = title[:-4]
    data = {"base": "/" + token, "title": title}
    # Static OG/description tags for link-preview crawlers, which don't run the
    # JS that lists the folder. No live listing here (kept O(1)), so the
    # description is generic.
    desc = "Shared folder · tsync"
    return (
        BROWSE_HTML
        .replace("__OG_TITLE__", html.escape(title, quote=True))
        .replace("__OG_DESC__", html.escape(desc, quote=True))
        .replace("__SHARE_DATA__", json.dumps(data))
    )


def _asset(name):
    with open(os.path.join(os.path.dirname(__file__), name)) as f:
        return f.read()


BROWSE_HTML = (
    _asset("browse.html")
    .replace("__PREVIEW_KINDS__", json.dumps(PREVIEW_KINDS))
    .replace("__PLAYER_JS__", _asset("player.js"))
)
