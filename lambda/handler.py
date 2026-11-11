"""tsync share Lambda.

Serves shared files/folders from the tsync S3 chunk store. A request path is
``/{token}[/sub]`` where ``token`` is the random hex id of a *share manifest*
(written by ``tsync share``); the full S3 key is ``SHARES_PREFIX + token``. Routes:

- ``/{token}``            dir share -> HTML file browser; media file share -> the
                          same page as a viewer for a request accepting
                          ``text/html``; anything else -> download
- ``/{token}/download``   assemble the whole artifact (file, or dir as a zip)
- ``/{token}/f``          (file) 302 to a presigned inline GET (``?json=1``
                          returns the URL as JSON for the viewer)
- ``/{token}/list?path=`` (dir) one directory level as JSON: subdirs + files+sizes
- ``/{token}/f?path=``    (dir) assemble one file; 302 to a presigned GET
                          (``?json=1`` returns the URL as JSON for inline media
                          preview, ``?dl=1`` forces an attachment download)

A share manifest names its domain, from which the chunk and manifest prefixes
follow. A dir share stores only the folder's id; the browser lists one folder at
a time via ``/list``, so ``tsync share`` and page load stay O(1) regardless of
how many files the directory holds. Assembled artifacts are cached under
``SHARES_PREFIX + "cache/"`` and served via a short-lived presigned GET (responses
are size-capped, so we never stream bodies ourselves). Everything in that subtree
is rebuildable, which is what makes ``tsync share --clear-cache`` safe.

Size guard: a single file (or per-file preview) and the running total of a folder
zip are both capped at MAX_BYTES (default 10 GiB) -> 413, so a build can't blow
past the /tmp ephemeral disk or run for the full 900 s timeout. The multipart
path also caps a single file at ~80 GB (10,000 parts). Upgrade path when these
bite: build on Fargate.
"""

import base64
import concurrent.futures
import html
import json
import os
import re
import time
import traceback
import urllib.parse
import zipfile

import manifest
from share_common import ShareError, cache_prefix, content_disposition

SHARES_PREFIX = os.environ.get("SHARES_PREFIX", "tsync/shares/")  # guard: keys must start with this
# A token is hex, so nothing published can ever land in here.
CACHE_PREFIX = cache_prefix(SHARES_PREFIX)
# Domains sit beside the shares: <root>/<domain>/{manifests,chunks}/.
_root, _sep, _ = SHARES_PREFIX.rstrip("/").rpartition("/")
ROOT_PREFIX = _root + "/" if _sep else ""
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(10 * 1024**3)))
# http-proxy §A9.9: published site shares, served on a host of their own.
SITES_BUCKET = os.environ.get("SITES_BUCKET") or None
SITES_DOMAIN = (os.environ.get("SITES_DOMAIN") or "").lower() or None
SITE_PAGE_MAX_BYTES = 4 * 1024 * 1024

# Pick the storage backend by env; import lazily so one deployment zip runs on
# either cloud without importing the other's SDK.
if os.environ.get("STORE", "aws") == "gcs":
    from store_gcs import Store
else:
    from store_aws import Store

store = Store()


def too_large():
    return ShareError(413, "too large to assemble (limit %d bytes)" % MAX_BYTES)


def domain_root(share):
    return ROOT_PREFIX + share["domain"] + "/"


def chunk_prefix(share):
    return domain_root(share) + "chunks/"


def shared_folder(share):
    """The shared folder's namespace prefix."""
    return domain_root(share) + "manifests/" + share["folderId"] + "/"


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
# reads each child. A dir share stores the folder's id, whose namespace is
# <...>/manifests/<id>/.


def ns_base(dir_prefix):
    # <...>/manifests/<id>/  ->  <...>/manifests/
    return dir_prefix.rstrip("/").rsplit("/", 1)[0] + "/"


def child_entry(base, key):
    """[child_object], with the parsed manifest of a file (None for a folder)
    last."""
    try:
        body = get_bytes(key)
    except FileNotFoundError:
        return None
    # A file manifest and a folder marker share this namespace and are told
    # apart by the body: the first is binary and starts with the magic, the
    # second is JSON.
    if manifest.is_manifest(body):
        try:
            m = manifest.Manifest(body)
        except manifest.Malformed:
            return None
        return (m.name, key, False, m.size, m)
    try:
        m = json.loads(body)
    except ValueError:
        return None
    if m.get("dir"):
        return (m.get("name", ""), base + m["id"] + "/", True, None, None)
    return None


def child_object(base, key):
    """A listed child key as (name, key, is_dir, size), else None.
    For a subdir, key is its own namespace prefix; for a file, its manifest key."""
    e = child_entry(base, key)
    return e[:4] if e else None


def child_objects(ns_prefix, read=child_object):
    """Direct children of a folder namespace, from a live listing.
    One GET per child to read names/ids/sizes from bodies (folders are small)."""
    base = ns_base(ns_prefix)
    children = (read(base, k) for k in store.list_keys(ns_prefix) if k != ns_prefix)
    return [c for c in children if c]


# A child key is its name's hash, so the name behind a listed key never changes:
# its body read is kept, and every walk still lists live, so a name added or
# removed is seen at once. Only the size, and a same-named folder recreated
# under a new id, can be CHILD_TTL old, which resolving does not read or
# tolerates; a player walking N segments then reads each body once.
CHILD_TTL = 30
_child_cache = {}


def cached_child(base, key):
    now = time.time()
    hit = _child_cache.get(key)
    if hit and now - hit[0] < CHILD_TTL:
        return hit[1]
    if len(_child_cache) > 100_000:
        for k in [k for k, (t, _) in _child_cache.items() if now - t >= CHILD_TTL]:
            del _child_cache[k]
    c = child_object(base, key)
    _child_cache[key] = (now, c)
    return c


def resolve(dir_prefix, rel):
    """Walk [rel] (decoded, '/'-separated) from the shared folder by matching
    names. Returns ('dir', namespace_prefix) or ('file', manifest_key), else
    None."""
    kind, loc = "dir", dir_prefix
    for part in [p for p in rel.split("/") if p]:
        if kind != "dir":
            return None
        match = next((c for c in child_objects(loc, cached_child) if c[0] == part), None)
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


def check_size(m):
    if m.size > MAX_BYTES or m.count > 10000:
        raise too_large()


def assemble(m, chunk_prefix, cache_key, ceiling=True):
    """Write a file's bytes to cache_key by server-side chunk assembly (no /tmp).
    Applies the size / count guards, then hands the ordered chunk keys to the
    store, which stitches them (S3 multipart-copy / GCS compose). Without
    [ceiling], only the store's own part count bounds it."""
    if ceiling:
        check_size(m)
    elif m.count > 10000:
        raise too_large()
    if m.count == 0:
        store.put_bytes(cache_key, b"")
        return
    store.assemble([chunk_key(chunk_prefix, k) for k in m.keys()], cache_key)


def mtime_tuple(mtime_ns):
    try:
        t = time.localtime(mtime_ns / 1e9)
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
    write_zip(iter_dir_entries(shared_folder(share), root), chunk_prefix(share), cache_key)


# ── Content types ───────────────────────────────────────────────────────────

# Extension -> MIME type. Shared with the OCaml http-proxy share server, which
# embeds this same file at build time, so the table has one definition.
with open(os.path.join(os.path.dirname(__file__), "mime.json")) as _f:
    MIME = json.load(_f)
# http-proxy §A9.5: extensions whose type the first bytes decide.
SIGNATURES = MIME.pop("@signatures")


def extension(name):
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def mime_type(name):
    return MIME.get(extension(name))


def content_type(cache_key, name, size):
    """The served type, None when unknown: by name, unless a signature of its
    extension matches the bytes at every listed offset inside the file."""
    sig = SIGNATURES.get(extension(name))
    if sig and size > 0:
        at = {int(o): b for o, b in sig["bytes"].items() if int(o) < size}
        head = store.get_range(cache_key, 0, max(at)) if at else b""
        if all(head[o] == b for o, b in at.items()):
            return sig["type"]
    return mime_type(name)


HLS_MIME = "application/vnd.apple.mpegurl"
# Shortcut files naming a web address: .url, .webloc, .desktop.
LINK_MIMES = {"application/x-mswinurl", "application/x-webloc", "application/x-desktop"}
# object-store-common §6: a playlist is answered whole, never redirected.
PLAYLIST_MAX_BYTES = 1024 * 1024


def preview_kind(mime):
    """How browse.html should preview a file with this MIME type."""
    mime = mime.split(";", 1)[0].strip()
    if mime.startswith("image/"):
        return "image"
    if mime.startswith("audio/"):
        return "audio"
    if mime.startswith("video/"):
        return "video"
    if mime == HLS_MIME:
        return "hls"
    if mime == "application/pdf":
        return "pdf"
    if mime == "text/html":
        return "html"
    if mime in LINK_MIMES:
        return "link"
    return "text"  # text/plain, application/json, application/xml


def is_media(name):
    """Whether a shared file opens the viewer page rather than downloading:
    what a browser plays or displays by itself, or a link file the page follows."""
    mime = mime_type(name)
    return mime is not None and preview_kind(mime) in ("image", "audio", "video", "pdf", "link")


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
        "headers": {
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "private",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
        },
        "body": body,
    }


# ── Routing ─────────────────────────────────────────────────────────────────


def valid_token(token):
    # The token is the manifest's random hex id; the key lives under our own
    # prefix, so a hex-only token can never point outside it.
    return bool(token) and all(c in "0123456789abcdef" for c in token)


def load_share(token):
    if not valid_token(token):
        raise ShareError(400, "bad token")
    manifest_key = SHARES_PREFIX + token
    try:
        share = get_json(manifest_key)
    except FileNotFoundError:
        raise ShareError(404, "not found")
    if share.get("v") != 1:
        raise ShareError(502, "unsupported share manifest")
    if time.time() > share.get("expires", 0):
        raise ShareError(410, "link expired")
    # 02 §2.14: [site] is true, on a folder share only.
    if "site" in share and (share["site"] is not True or share.get("type") != "dir"):
        raise ShareError(502, "corrupt share manifest")
    return share


def artifact(token, share, m=None):
    # The whole artifact (a file's bytes, or a directory zipped) is cached under
    # CACHE_PREFIX and served presigned. For a dir this freezes the zip at
    # first-download time; fine given the short share TTL.
    cache_key = CACHE_PREFIX + token + ".data"
    if not object_exists(cache_key):
        if share["type"] == "file":
            assemble(
                m or file_manifest(share["key"]), chunk_prefix(share), cache_key
            )
        elif share["type"] == "dir":
            build_dir_zip(share, cache_key)
        else:
            raise ShareError(400, "unknown share type")
    return cache_key


def download_artifact(token, share, m=None):
    return redirect(
        store.signed_url(artifact(token, share, m), share["filename"], inline=False)
    )


def file_answer(cache_key, name, size, as_download, want_json):
    ctype = content_type(cache_key, name, size)
    url = store.signed_url(cache_key, name, content_type=ctype, inline=not as_download)
    if want_json:
        return json_response(
            {"url": url, "name": name, "contentType": ctype, "size": size}
        )
    return redirect(url)


def serve_shared_file(token, share, want_json):
    m = file_manifest(share["key"])
    return file_answer(
        artifact(token, share, m), share["filename"], m.size,
        as_download=False, want_json=want_json,
    )


def list_dir(share, rel):
    """One directory level under the share: (subdir names, [(name, size)]).
    ponytail: one GET per child to read names/sizes from bodies — fine for normal
    folders; a folder with thousands of direct children pays that many GETs."""
    ns = shared_folder(share)
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


def shared_file(share, path):
    """(relative path, manifest) of a file under a folder share."""
    rel = safe_rel(path)
    if not rel:
        raise ShareError(400, "not a file")
    r = resolve(shared_folder(share), rel)
    if not r or r[0] != "file":
        raise ShareError(404, "file not found")
    return rel, file_manifest(r[1])


def assembled(share, m, ceiling=True):
    """The cached key of a shared file's bytes, assembled on first use."""
    cache_key = CACHE_PREFIX + m.h1 + "-" + m.h2 + ".data"
    if not object_exists(cache_key):
        assemble(m, chunk_prefix(share), cache_key, ceiling)
    return cache_key


def serve_file(share, path, as_download, want_json):
    rel, m = shared_file(share, path)
    return file_answer(
        assembled(share, m), os.path.basename(rel), m.size, as_download, want_json
    )


SERVED_HEADERS = {
    "Cache-Control": "private",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "sandbox",
}


def url_parts(raw):
    """An encoded path's segments, each decoded after the split."""
    # unquote keeps a malformed escape as is, which the http-proxy refuses.
    if re.search(r"%(?![0-9A-Fa-f]{2})", raw):
        raise ShareError(400, "bad path")
    try:
        parts = [urllib.parse.unquote(p, errors="strict") for p in raw.split("/") if p]
    except UnicodeDecodeError:
        raise ShareError(400, "bad path")
    if any("/" in p for p in parts):
        raise ShareError(404, "file not found")
    return parts


def serve_path(share, raw):
    """http-proxy §A9.3 `p/<path>` (object-store-common §6): a playlist is
    answered whole, since a player resolves its relative URIs against the URL
    it finally read; anything else is redirected as for `f`."""
    rel, m = shared_file(share, "/".join(url_parts(raw)))
    name = os.path.basename(rel)
    if mime_type(name) != HLS_MIME:
        return file_answer(assembled(share, m), name, m.size, False, False)
    if m.size > PLAYLIST_MAX_BYTES:
        raise ShareError(413, "playlist too large")
    return {
        "statusCode": 200,
        "headers": dict(
            SERVED_HEADERS,
            **{
                "Content-Type": HLS_MIME,
                "Content-Disposition": content_disposition(True, name),
            },
        ),
        "body": base64.b64encode(get_bytes(assembled(share, m))).decode(),
        "isBase64Encoded": True,
    }


PREVIEW_FETCHERS = (
    "facebookexternalhit", "facebot", "twitterbot", "whatsapp", "slackbot",
    "telegrambot", "discordbot", "linkedinbot", "skypeuripreview",
)


def preview_fetcher(event):
    agent = (event.get("headers") or {}).get("user-agent", "").lower()
    return any(f in agent for f in PREVIEW_FETCHERS)


def wants_html(event):
    """Whether the request is a browser navigation: `text/html` listed
    explicitly, which `*/*` and a missing header are not; or a link-preview
    fetcher, which gets the page whatever it accepts."""
    accept = (event.get("headers") or {}).get("accept", "")
    return any(
        r.split(";")[0].strip().lower() == "text/html" for r in accept.split(",")
    ) or preview_fetcher(event)


# http-proxy §A9.8: constants of 05 §8.
PREVIEW_MAX_BYTES = 300 * 1024
PREVIEW_SIZE = 800
PREVIEW_MIN_SIDE = 300


def jpeg_dimensions(b):
    """(width, height) from the frame header of tsync's own encoder output,
    else None."""
    n = len(b)
    if n < 4 or b[:2] != b"\xff\xd8" or b[-2:] != b"\xff\xd9":
        return None
    i = 2
    while True:
        if i >= n or b[i] != 0xFF:
            return None
        j = i + 1
        while j < n and b[j] == 0xFF:
            j += 1
        if j >= n:
            return None
        m = b[j]
        if 0xD0 <= m <= 0xD7 or m == 0x01:
            i = j + 1
            continue
        if m in (0x00, 0xDA, 0xD9) or j + 2 >= n:
            return None
        length = (b[j + 1] << 8) | b[j + 2]
        if length < 2 or j + 1 + length > n:
            return None
        if m in (0xC0, 0xC2):
            if length < 8:
                return None
            precision, components = b[j + 3], b[j + 8]
            h = (b[j + 4] << 8) | b[j + 5]
            w = (b[j + 6] << 8) | b[j + 7]
            if precision == 8 and h > 0 and w > 0 and components in (1, 3):
                return (w, h)
            return None
        if 0xC1 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
            return None
        i = j + 1 + length


def valid_preview(b):
    d = len(b) <= PREVIEW_MAX_BYTES and jpeg_dimensions(b)
    return bool(d) and max(d) == PREVIEW_SIZE and min(d) >= PREVIEW_MIN_SIDE


def image_response(body, content_type):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": content_type, "X-Content-Type-Options": "nosniff"},
        "body": base64.b64encode(body).decode(),
        "isBase64Encoded": True,
    }


# ── Site shares (http-proxy §A9.9, security §6.5) ──────────────────────────

# The mime table types these text/plain for the share page's previews, under
# which a browser runs neither.
SITE_TYPES = {
    "js": "text/javascript; charset=utf-8",
    "mjs": "text/javascript; charset=utf-8",
    "css": "text/css; charset=utf-8",
}
INDEX_PAGES = ("index.html", "index.htm")
RESERVED_ROOT_NAME = ".tsync-ext"


def sites_enabled():
    return SITES_BUCKET is not None and SITES_DOMAIN is not None


def site_record(token):
    return CACHE_PREFIX + token + ".site"


def site_prefix(token):
    return token + "/"


def share_state(token):
    """'live', 'gone' (absent or expired) or 'unknown' (no answer)."""
    try:
        load_share(token)
        return "live"
    except ShareError as e:
        return "gone" if e.code in (404, 410) else "unknown"
    except Exception:
        return "unknown"


def remove_site(token):
    """The copy, then its record, so that a record says the copy is whole."""
    keys = list(store.site_keys(site_prefix(token)))
    if keys:
        store.site_delete(keys)
    store.delete(site_record(token))


def load_or_remove(token):
    """[load_share], removing the published site of a share found gone."""
    try:
        return load_share(token)
    except ShareError as e:
        # One HEAD for a token never published; the sweep catches a copy left
        # without its record.
        if e.code in (404, 410) and sites_enabled():
            try:
                if object_exists(site_record(token)):
                    remove_site(token)
            except Exception:
                traceback.print_exc()
        raise


def site_files(share):
    """(path below the folder, manifest) of every file of a folder share;
    symlinks, unreadable manifests and the reserved root folder left out."""
    root_share = share["folderId"] == ".tsync-root"

    def walk(ex, ns, prefix):
        base = ns_base(ns)
        keys = [k for k in store.list_keys(ns) if k != ns]
        for e in ex.map(lambda k: child_entry(base, k), keys):
            if e is None:
                continue
            name, key, is_dir, _, m = e
            if root_share and not prefix and name == RESERVED_ROOT_NAME:
                continue
            if is_dir:
                yield from walk(ex, key, prefix + name + "/")
            elif m.symlink is None:
                yield prefix + name, m

    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
        return list(walk(ex, shared_folder(share), ""))


def publish_file(share, token, rel, m):
    """Copies one file into the sites bucket, unless it is there with the
    manifest's size and time, which resumes a publication cut short."""
    dest = site_prefix(token) + rel
    if store.site_head(dest) == (m.size, str(m.mtime)):
        return dest
    cache_key = assembled(share, m, ceiling=False)
    name = os.path.basename(rel)
    ctype = (
        SITE_TYPES.get(extension(name))
        or content_type(cache_key, name, m.size)
        or "application/octet-stream"
    )
    store.site_copy(cache_key, dest, ctype, m.mtime, share["expires"])
    return dest


def publish_site(share, token):
    """The whole folder, then the record: anything of the copy that the folder
    no longer holds is removed, and a copy whose share went in the meantime is
    removed again."""
    try:
        files = list(site_files(share))
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
            kept = set(ex.map(lambda f: publish_file(share, token, *f), files))
        stale = [k for k in store.site_keys(site_prefix(token)) if k not in kept]
        if stale:
            store.site_delete(stale)
    except Exception:
        traceback.print_exc()
        raise ShareError(502, "site not published")
    state = share_state(token)
    if state == "gone":
        # A revocation removed the copy while this one was written.
        remove_site(token)
        raise ShareError(404, "not found")
    if state != "live":
        raise ShareError(502, "site not published")
    store.put_bytes(site_record(token), b"")


def ensure_published(share, token):
    """One sites bucket per store, and [remove_site] drops the record with the
    copy, so the record alone says the copy is there."""
    if not object_exists(site_record(token)):
        publish_site(share, token)


def site_redirect(token):
    return {
        "statusCode": 302,
        "headers": {
            "Location": "https://%s/%s/" % (SITES_DOMAIN, token),
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
        },
    }


def index_page(token, rel):
    """(key, head) of a folder's index page, else None."""
    for page in INDEX_PAGES:
        key = site_prefix(token) + (rel + "/" if rel else "") + page
        head = store.site_head(key)
        if head is not None:
            return key, head
    return None


def serve_site(token, raw):
    """`<sites domain>/<token>/<path>`: a page answered whole, so it and its
    relative links stay on the sites domain; a folder by its index page; any
    other file by a redirect to the bucket's own endpoint."""
    share = load_or_remove(token)
    if share.get("site") is not True:
        raise ShareError(404, "not found")
    ensure_published(share, token)
    parts = url_parts(raw)
    if any(p in (".", "..") for p in parts):
        raise ShareError(400, "bad path")
    rel = "/".join(parts)
    if raw == "" or raw.endswith("/"):
        found = index_page(token, rel)
    else:
        key = site_prefix(token) + rel
        head = store.site_head(key)
        if head is None and index_page(token, rel) is not None:
            return {"statusCode": 301, "headers": {"Location": "/%s/%s/" % (token, raw)}}
        found = (key, head) if head is not None else None
    if found is None:
        raise ShareError(404, "not found")
    key, head = found
    ctype = mime_type(key) or ""
    if ctype.startswith("text/html") and head[0] <= SITE_PAGE_MAX_BYTES:
        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": ctype,
                "Cache-Control": "no-cache",
                "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff",
            },
            "body": base64.b64encode(store.site_get(key)).decode(),
            "isBase64Encoded": True,
        }
    return {
        "statusCode": 302,
        "headers": {"Location": store.site_url(key), "Cache-Control": "no-store"},
    }


def sweep_sites():
    """Removes every published site whose share is gone; a share that cannot be
    read keeps its site."""
    removed = 0
    for token in list(store.site_tokens()):
        if share_state(token) == "gone":
            remove_site(token)
            removed += 1
    return removed


def request_host(event):
    headers = event.get("headers") or {}
    host = (event.get("requestContext") or {}).get("domainName") or headers.get("host", "")
    return host.split(":")[0].lower()


def handle_sites_host(event):
    raw = event.get("rawPath", "/")[1:]
    token, slash, rest = raw.partition("/")
    if not valid_token(token):
        raise ShareError(404, "not found")
    if not slash:
        return {"statusCode": 301, "headers": {"Location": "/%s/" % token}}
    return serve_site(token, rest)


def preview_response(token):
    """The stored preview image when valid, else the generic one: this function
    carries no thumbnailer."""
    try:
        b = get_bytes(CACHE_PREFIX + token + ".jpg")
    except FileNotFoundError:
        b = b""
    if valid_preview(b):
        return image_response(b, "image/jpeg")
    return image_response(CARD_PNG, "image/png")


def handler(event, context):
    # The scheduler's input: a request through the function URL is never one.
    if event.get("sweep") is True:
        removed = sweep_sites() if sites_enabled() else 0
        print("sites swept: %d removed" % removed)
        return {"removed": removed}
    try:
        if sites_enabled() and request_host(event) == SITES_DOMAIN:
            return handle_sites_host(event)
        parts = event.get("rawPath", "/").strip("/").split("/")
        token = parts[0] if parts else ""
        sub = parts[1] if len(parts) > 1 else ""
        if not token:
            raise ShareError(400, "missing token")
        share = load_or_remove(token)
        q = event.get("queryStringParameters") or {}
        if share.get("type") not in ("file", "dir"):
            raise ShareError(400, "unknown share type")
        is_dir = share["type"] == "dir"
        if sub == "preview":
            return preview_response(token)
        if sub == "":
            if is_dir and share.get("site") and sites_enabled() and not preview_fetcher(event):
                ensure_published(share, token)
                return site_redirect(token)
            if is_dir:
                return html_response(render_browse(share, token, event))
            if is_media(share["filename"]):
                m = file_manifest(share["key"])
                check_size(m)
                if wants_html(event):
                    resp = html_response(render_browse(share, token, event))
                else:
                    resp = download_artifact(token, share, m)
                resp["headers"]["Vary"] = "Accept, User-Agent"
                return resp
            return download_artifact(token, share)
        if sub == "download":
            return download_artifact(token, share)
        if not is_dir and sub == "f":
            return serve_shared_file(token, share, want_json=q.get("json") == "1")
        if is_dir and sub == "list":
            return list_response(share, q.get("path", ""))
        if is_dir and sub == "p":
            return serve_path(share, (event.get("rawPath", "").split("/", 3) + [""])[3])
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
    # Encoded, as a function URL's rawPath is: `p/<path>` decodes it after the
    # split, so the path as sent (gunicorn's RAW_URI), not Werkzeug's decoded one.
    raw = request.environ.get("RAW_URI", "").split("?", 1)[0]
    event = {
        "rawPath": raw or urllib.parse.quote(request.path),
        "queryStringParameters": dict(request.args),
        "headers": {k.lower(): v for k, v in request.headers.items()},
    }
    resp = handler(event, None)
    body = resp.get("body", "")
    if resp.get("isBase64Encoded"):
        body = base64.b64decode(body)
    return (body, resp["statusCode"], resp.get("headers", {}))


def script_json(obj):
    """JSON that cannot close the script element it is embedded in."""
    return (
        json.dumps(obj)
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("&", "\\u0026")
    )


def origin(event):
    """https and the requester's host: the page's absolute URLs, for that
    requester alone."""
    headers = event.get("headers") or {}
    host = headers.get("x-forwarded-host") or headers.get("host") or "localhost"
    return "https://" + host.split(",")[0].strip()


def render_browse(share, token, event):
    title = share.get("filename", "share")
    is_file = share["type"] == "file"
    if not is_file and title.endswith(".zip"):
        title = title[:-4]
    data = {"base": "/" + token, "title": title}
    if is_file:
        data["file"] = True
    # Static OG/description tags for link-preview crawlers, which don't run the
    # JS that lists the folder. No live listing here (kept O(1)), so the
    # description is generic.
    desc = "Shared file · tsync" if is_file else "Shared folder · tsync"
    values = {
        "__OG_TITLE__": html.escape(title, quote=True),
        "__OG_DESC__": html.escape(desc, quote=True),
        "__SHARE_DATA__": script_json(data),
        "__OG_IMAGE__": html.escape(origin(event) + "/" + token + "/preview", quote=True),
    }
    # One pass: a substituted value is never scanned for placeholders.
    return re.sub("|".join(values), lambda m: values[m.group()], BROWSE_HTML)


def _asset(name, mode="r"):
    with open(os.path.join(os.path.dirname(__file__), name), mode) as f:
        return f.read()


CARD_PNG = _asset("share-card.png", "rb")


BROWSE_HTML = (
    _asset("browse.html")
    .replace("__PREVIEW_KINDS__", json.dumps(PREVIEW_KINDS))
    .replace("__PLAYER_JS__", _asset("player.js"))
)
