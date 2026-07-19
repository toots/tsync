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
how many files the directory holds. Assembled artifacts are cached next to / under
the manifest and served via a short-lived presigned GET (responses are size-capped,
so we never stream bodies ourselves).

Size guard: a single file (or per-file preview) and the running total of a folder
zip are both capped at MAX_BYTES (default 10 GiB) -> 413, so a build can't blow
past the /tmp ephemeral disk or run for the full 900 s timeout. The multipart
path also caps a single file at ~80 GB (10,000 parts). Upgrade path when these
bite: build on Fargate.
"""

import concurrent.futures
import html
import json
import os
import time
import zipfile
from urllib.parse import quote

import boto3
from botocore.exceptions import ClientError

BUCKET = os.environ["BUCKET"]
SHARES_PREFIX = os.environ["SHARES_PREFIX"]  # guard: keys must start with this
PRESIGN_TTL = int(os.environ.get("PRESIGN_TTL", "600"))
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(10 * 1024**3)))
CHUNK_READ = 1024 * 1024

s3 = boto3.client("s3")


class ShareError(Exception):
    def __init__(self, code, msg):
        self.code = code
        self.msg = msg


def too_large():
    return ShareError(413, "too large to assemble (limit %d bytes)" % MAX_BYTES)


# ── S3 helpers ──────────────────────────────────────────────────────────────


def get_bytes(key):
    try:
        return s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    except ClientError as e:
        if e.response["Error"]["Code"] in ("NoSuchKey", "404", "NoSuchBucket"):
            raise FileNotFoundError(key)
        raise


def get_json(key):
    return json.loads(get_bytes(key))


def object_exists(key):
    try:
        s3.head_object(Bucket=BUCKET, Key=key)
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
            return False
        raise


def chunk_key(chunk_prefix, c):
    return chunk_prefix + c["h1"] + "-" + c["h2"]


# ── Key codec (mirrors lib/local_io/fs_util.ml) ─────────────────────────────
#
# tsync stores object keys with reserved/control chars percent-encoded per path
# component (so keys are valid on any local filesystem). The backend wrapper
# encodes/decodes transparently, but this Lambda talks to raw boto3, so it must
# do the same: decode encoded keys for display, encode user paths for access.

_RESERVED = set(':*?"<>|\\&=%')


def encode_component(s):
    return "".join(
        "%%%02X" % ord(c) if (c in _RESERVED or ord(c) < 32) else c for c in s
    )


def encode_key(s):
    return "/".join(encode_component(p) for p in s.split("/"))


def decode_component(s):
    out = []
    i, n = 0, len(s)
    while i < n:
        if s[i] == "%" and i + 2 < n:
            try:
                out.append(chr(int(s[i + 1 : i + 3], 16)))
                i += 3
                continue
            except ValueError:
                pass
        out.append(s[i])
        i += 1
    return "".join(out)


def decode_key(s):
    return "/".join(decode_component(p) for p in s.split("/"))


def safe_rel(path):
    """A browse-supplied path (decoded, '/'-separated) under the shared dir.
    Reject anything that could escape the prefix."""
    parts = [p for p in (path or "").split("/") if p]
    if any(p in (".", "..") for p in parts):
        raise ShareError(400, "bad path")
    return "/".join(parts)


def sanitize_filename(name):
    return name.replace('"', "").replace("\\", "").replace("\n", "").replace("\r", "")


def content_disposition(inline, filename):
    # RFC 5987: HTTP headers are ASCII, so non-ASCII names (accents, NFD combining
    # marks) go in filename* as percent-encoded UTF-8, with an ASCII filename
    # fallback. Putting raw UTF-8 in filename="..." makes S3 reject the request.
    disp = "inline" if inline else "attachment"
    ascii_name = sanitize_filename(filename).encode("ascii", "replace").decode("ascii")
    return "%s; filename=\"%s\"; filename*=UTF-8''%s" % (disp, ascii_name, quote(filename, safe=""))


def presign(cache_key, filename, content_type=None, inline=False):
    params = {
        "Bucket": BUCKET,
        "Key": cache_key,
        "ResponseContentDisposition": content_disposition(inline, filename),
    }
    if content_type:
        params["ResponseContentType"] = content_type
    return s3.generate_presigned_url("get_object", Params=params, ExpiresIn=PRESIGN_TTL)


# ── Assembly ────────────────────────────────────────────────────────────────


def file_manifest(key):
    """Load a file manifest, rejecting in-progress / symlink manifests."""
    try:
        m = get_json(key)
    except FileNotFoundError:
        raise ShareError(404, "file not found")
    if m.get("dirty"):
        raise ShareError(409, "upload in progress, try again shortly")
    if m.get("symlink") is not None:
        raise ShareError(400, "cannot serve a symlink directly")
    return m


def assemble(m, chunk_prefix, cache_key):
    """Write a file's bytes to cache_key by server-side chunk copy (no /tmp)."""
    if m.get("size", 0) > MAX_BYTES:
        raise too_large()
    chunks = sorted(m["chunks"], key=lambda c: c["index"])
    if not chunks:
        s3.put_object(Bucket=BUCKET, Key=cache_key, Body=b"")
        return
    if len(chunks) == 1:
        s3.copy_object(
            Bucket=BUCKET,
            Key=cache_key,
            CopySource={"Bucket": BUCKET, "Key": chunk_key(chunk_prefix, chunks[0])},
        )
        return
    if len(chunks) > 10000:
        raise too_large()
    upload_id = s3.create_multipart_upload(Bucket=BUCKET, Key=cache_key)["UploadId"]
    try:
        parts = []
        for n, c in enumerate(chunks, start=1):
            r = s3.upload_part_copy(
                Bucket=BUCKET,
                Key=cache_key,
                UploadId=upload_id,
                PartNumber=n,
                CopySource={"Bucket": BUCKET, "Key": chunk_key(chunk_prefix, c)},
            )
            parts.append({"ETag": r["CopyPartResult"]["ETag"], "PartNumber": n})
        s3.complete_multipart_upload(
            Bucket=BUCKET,
            Key=cache_key,
            UploadId=upload_id,
            MultipartUpload={"Parts": parts},
        )
    except Exception:
        s3.abort_multipart_upload(Bucket=BUCKET, Key=cache_key, UploadId=upload_id)
        raise


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
                    m = get_json(key)
                except FileNotFoundError:
                    continue  # deleted between listing and build
                if m.get("dirty"):
                    continue  # transient mid-upload; etag changes once complete
                total += m.get("size", 0)
                if total > MAX_BYTES:
                    raise too_large()
                zi = zipfile.ZipInfo(name, date_time=mtime_tuple(m.get("mtime", 0)))
                if m.get("symlink") is not None:
                    zi.external_attr = 0xA1FF << 16  # S_IFLNK | 0777
                    zf.writestr(zi, m["symlink"].encode())
                    continue
                zi.compress_type = zipfile.ZIP_STORED
                with zf.open(zi, "w") as w:
                    for c in sorted(m["chunks"], key=lambda c: c["index"]):
                        body = s3.get_object(
                            Bucket=BUCKET, Key=chunk_key(chunk_prefix, c)
                        )["Body"]
                        for buf in iter(lambda: body.read(CHUNK_READ), b""):
                            w.write(buf)
        s3.upload_file(tmp, BUCKET, cache_key)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def iter_dir_entries(dir_prefix, root):
    """Recursively enumerate a shared directory, yielding (zip_name, key|None).
    Names are rooted under [root] so unzip creates a single top folder."""
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=dir_prefix):
        for obj in page.get("Contents", []):
            enc_rel = obj["Key"][len(dir_prefix):]
            if enc_rel == "":
                continue  # the shared dir's own marker
            rel = decode_key(enc_rel)
            name = root + "/" + rel
            yield name, (None if enc_rel.endswith("/") else obj["Key"])


def build_dir_zip(share, cache_key):
    root = share.get("filename", "share")
    if root.endswith(".zip"):
        root = root[:-4]
    write_zip(
        iter_dir_entries(share["dirPrefix"], root), share["chunkPrefix"], cache_key
    )


# ── Content types ───────────────────────────────────────────────────────────

# Extensions the browser renders as plain text in the preview iframe.
TEXT_EXT = [
    "txt", "md", "log", "csv", "tsv", "ini", "conf", "cfg", "toml", "yaml", "yml",
    "sh", "bash", "zsh", "py", "js", "mjs", "ts", "jsx", "tsx", "css", "c", "h",
    "cpp", "cc", "hpp", "go", "rs", "rb", "java", "kt", "swift", "php", "pl", "lua",
    "sql", "r", "m", "diff", "patch",
]

MIME = {
    "jpg": "image/jpeg", "jpeg": "image/jpeg", "jfif": "image/jpeg", "png": "image/png",
    "apng": "image/apng", "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
    "bmp": "image/bmp", "avif": "image/avif", "ico": "image/x-icon",
    "mp3": "audio/mpeg", "flac": "audio/flac", "wav": "audio/wav", "ogg": "audio/ogg",
    "oga": "audio/ogg", "m4a": "audio/mp4", "aac": "audio/aac", "opus": "audio/opus",
    "weba": "audio/webm",
    "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm", "mov": "video/quicktime",
    "mkv": "video/x-matroska", "ogv": "video/ogg",
    "pdf": "application/pdf",
    "json": "application/json; charset=utf-8", "xml": "application/xml; charset=utf-8",
    "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
    **{e: "text/plain; charset=utf-8" for e in TEXT_EXT},
}


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
    return manifest_key, share


def download_artifact(manifest_key, share):
    # The whole artifact (a file's bytes, or a directory zipped) is cached at
    # <manifest>.data and served presigned. For a dir this freezes the zip at
    # first-download time; fine given the short share TTL.
    cache_key = manifest_key + ".data"
    if not object_exists(cache_key):
        if share["type"] == "file":
            build_file(share["key"], share["chunkPrefix"], cache_key)
        elif share["type"] == "dir":
            build_dir_zip(share, cache_key)
        else:
            raise ShareError(400, "unknown share type")
    return redirect(presign(cache_key, share["filename"], inline=False))


def file_size(key):
    """size (bytes) of a file manifest, or None if missing/mid-upload."""
    try:
        m = get_json(key)
    except FileNotFoundError:
        return None
    return None if m.get("dirty") else m.get("size")


def list_dir(share, rel):
    """One directory level under the share: (subdir names, [(name, size)])."""
    dir_prefix = share["dirPrefix"]
    prefix = dir_prefix + (encode_key(rel) + "/" if rel else "")
    dirs, files = [], []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=prefix, Delimiter="/"):
        for cp in page.get("CommonPrefixes", []):
            enc = cp["Prefix"][len(prefix):].rstrip("/")
            dirs.append(decode_component(enc))
        for obj in page.get("Contents", []):
            enc = obj["Key"][len(prefix):]
            if enc == "":
                continue  # this dir's own marker
            files.append((decode_component(enc), obj["Key"]))
    # ponytail: one manifest read per file in THIS folder to show sizes, run
    # concurrently. Fine for normal folders; a folder with thousands of direct
    # children pays thousands of GETs. Ceiling: paginate/omit sizes if it bites.
    sizes = {}
    if files:
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
            sizes = dict(
                zip(
                    (k for _, k in files),
                    ex.map(file_size, (k for _, k in files)),
                )
            )
    return dirs, [(name, sizes.get(key)) for name, key in files]


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
    m = file_manifest(share["dirPrefix"] + encode_key(rel))
    cache_key = SHARES_PREFIX + m["h1"] + "-" + m["h2"] + ".data"
    if not object_exists(cache_key):
        assemble(m, share["chunkPrefix"], cache_key)
    name = os.path.basename(rel)
    ctype = mime_type(name)
    url = presign(cache_key, name, content_type=ctype, inline=not as_download)
    if want_json:
        return json_response(
            {"url": url, "name": name, "contentType": ctype, "size": m.get("size")}
        )
    return redirect(url)


def handler(event, context):
    try:
        parts = event.get("rawPath", "/").strip("/").split("/")
        token = parts[0] if parts else ""
        sub = parts[1] if len(parts) > 1 else ""
        if not token:
            raise ShareError(400, "missing token")
        manifest_key, share = load_share(token)
        q = event.get("queryStringParameters") or {}
        is_dir = share.get("type") == "dir"
        if sub == "":
            if is_dir:
                return html_response(render_browse(share, token))
            return download_artifact(manifest_key, share)
        if sub == "download":
            return download_artifact(manifest_key, share)
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


with open(os.path.join(os.path.dirname(__file__), "browse.html")) as _f:
    BROWSE_HTML = _f.read().replace("__PREVIEW_KINDS__", json.dumps(PREVIEW_KINDS))
