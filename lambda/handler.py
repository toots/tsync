"""tsync share Lambda.

Serves shared files/folders from the tsync S3 chunk store. A request path is
``/{token}[/sub]`` where ``token`` is the base64url of a *share manifest* S3 key
(written by ``tsync share``). Routes:

- ``/{token}``            folder share -> HTML file browser; file share -> download
- ``/{token}/download``   assemble the whole artifact (file, or folder as a zip)
- ``/{token}/f/{index}``  assemble one entry of a folder share; 302 to a presigned
                          GET (``?json=1`` returns the URL as JSON for inline media
                          preview, ``?dl=1`` forces an attachment download)

Assembled artifacts are cached next to / under the manifest and served via a
short-lived presigned GET (Function URL responses are size-capped, so we never
stream bodies ourselves).

Size guard: a single file (or per-file preview) and the running total of a folder
zip are both capped at MAX_BYTES (default 10 GiB) -> 413, so a build can't blow
past the /tmp ephemeral disk or run for the full 900 s timeout. The multipart
path also caps a single file at ~80 GB (10,000 parts). Upgrade path when these
bite: build on Fargate.
"""

import base64
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


def b64url_decode(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)).decode()


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


def build_zip(entries, chunk_prefix, cache_key):
    tmp = "/tmp/" + os.path.basename(cache_key)
    total = 0
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED, allowZip64=True) as zf:
            for e in entries:
                name = e["name"]
                if name.endswith("/"):
                    zf.writestr(zipfile.ZipInfo(name), b"")
                    continue
                try:
                    m = get_json(e["key"])
                except FileNotFoundError:
                    continue  # deleted since share time
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


def build(share, cache_key):
    chunk_prefix = share["chunkPrefix"]
    if share["type"] == "file":
        build_file(share["key"], chunk_prefix, cache_key)
    elif share["type"] == "zip":
        build_zip(share["entries"], chunk_prefix, cache_key)
    else:
        raise ShareError(400, "unknown share type")


# ── Content types ───────────────────────────────────────────────────────────

MIME = {
    "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif",
    "webp": "image/webp", "svg": "image/svg+xml", "bmp": "image/bmp", "avif": "image/avif",
    "mp3": "audio/mpeg", "flac": "audio/flac", "wav": "audio/wav", "ogg": "audio/ogg",
    "oga": "audio/ogg", "m4a": "audio/mp4", "aac": "audio/aac", "opus": "audio/opus",
    "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm", "mov": "video/quicktime",
    "mkv": "video/x-matroska", "ogv": "video/ogg",
    "pdf": "application/pdf", "txt": "text/plain", "md": "text/plain", "json": "application/json",
}


def mime_type(name):
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    return MIME.get(ext)


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
    try:
        manifest_key = b64url_decode(token)
    except Exception:
        raise ShareError(400, "bad token")
    if not manifest_key.startswith(SHARES_PREFIX):
        raise ShareError(403, "forbidden")
    try:
        share = get_json(manifest_key)
    except FileNotFoundError:
        raise ShareError(404, "not found")
    if time.time() > share.get("expires", 0):
        raise ShareError(410, "link expired")
    return manifest_key, share


def download_artifact(manifest_key, share):
    cache_key = manifest_key + ".data"
    if not object_exists(cache_key):
        build(share, cache_key)
    return redirect(presign(cache_key, share["filename"], inline=False))


def serve_entry(share, index, as_download, want_json):
    entries = share.get("entries", [])
    if index < 0 or index >= len(entries):
        raise ShareError(404, "no such entry")
    e = entries[index]
    if e["name"].endswith("/") or "key" not in e:
        raise ShareError(400, "not a file")
    m = file_manifest(e["key"])
    cache_key = SHARES_PREFIX + m["h1"] + "-" + m["h2"] + ".data"
    if not object_exists(cache_key):
        assemble(m, share["chunkPrefix"], cache_key)
    name = os.path.basename(e["name"].rstrip("/"))
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
        if sub == "":
            if share.get("type") == "zip":
                return html_response(render_browse(share, token))
            return download_artifact(manifest_key, share)
        if sub == "download":
            return download_artifact(manifest_key, share)
        if sub == "f":
            if len(parts) < 3 or not parts[2].isdigit():
                raise ShareError(400, "bad entry index")
            return serve_entry(
                share, int(parts[2]),
                as_download=q.get("dl") == "1", want_json=q.get("json") == "1",
            )
        raise ShareError(404, "not found")
    except ShareError as e:
        return err(e.code, e.msg)


def render_browse(share, token):
    data = {
        "base": "/" + token,
        "filename": share.get("filename", "share"),
        "entries": [
            {"name": e["name"], "i": i, "dir": e["name"].endswith("/")}
            for i, e in enumerate(share.get("entries", []))
        ],
    }
    return BROWSE_HTML.replace("__SHARE_DATA__", json.dumps(data))


BROWSE_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>tsync share</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 15px/1.5 -apple-system, system-ui, Segoe UI, Roboto, sans-serif; }
  header { padding: 16px 20px; border-bottom: 1px solid #8884; display: flex;
           align-items: center; gap: 12px; flex-wrap: wrap; }
  h1 { font-size: 18px; margin: 0; font-weight: 600; }
  .spacer { flex: 1; }
  a.btn, button.btn { font: inherit; padding: 7px 14px; border-radius: 8px;
           border: 1px solid #8886; background: #8881; color: inherit; cursor: pointer;
           text-decoration: none; }
  a.btn:hover, button.btn:hover { background: #8883; }
  main { max-width: 900px; margin: 0 auto; padding: 12px 16px 48px; }
  .crumbs { padding: 10px 4px; color: #888; }
  .crumbs a { color: inherit; cursor: pointer; text-decoration: none; }
  .crumbs a:hover { text-decoration: underline; }
  ul { list-style: none; margin: 0; padding: 0; }
  li { display: flex; align-items: center; gap: 10px; padding: 9px 8px;
       border-bottom: 1px solid #8882; }
  li .ico { width: 1.4em; text-align: center; }
  li .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis;
             white-space: nowrap; cursor: pointer; }
  li .name.plain { cursor: default; }
  li a.dl { color: #888; text-decoration: none; padding: 2px 6px; border-radius: 6px; }
  li a.dl:hover { background: #8883; }
  .empty { color: #888; padding: 24px 8px; }
  dialog { border: none; border-radius: 12px; padding: 0; max-width: 92vw; max-height: 92vh;
           background: #222; color: #eee; }
  dialog::backdrop { background: #000a; }
  .pv-head { display: flex; align-items: center; gap: 10px; padding: 10px 14px; }
  .pv-head .t { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .pv-body { padding: 0 14px 14px; text-align: center; }
  .pv-body img, .pv-body video { max-width: 86vw; max-height: 74vh; }
  .pv-body audio { width: min(70vw, 480px); }
  .x { cursor: pointer; border: none; background: none; color: inherit; font-size: 20px; }
</style>
</head>
<body>
<header>
  <h1 id="title">share</h1>
  <span class="spacer"></span>
  <a class="btn" id="dlall">Download all (zip)</a>
</header>
<main>
  <div class="crumbs" id="crumbs"></div>
  <ul id="list"></ul>
</main>

<dialog id="pv">
  <div class="pv-head"><span class="t" id="pvt"></span>
    <a class="btn" id="pvdl">Download</a>
    <button class="x" id="pvx" aria-label="Close">&times;</button></div>
  <div class="pv-body" id="pvb"></div>
</dialog>

<script>
const DATA = __SHARE_DATA__;
const B = DATA.base;
document.getElementById("dlall").href = B + "/download";
const nameNoZip = DATA.filename.replace(/\.zip$/, "");

const IMG = ["jpg","jpeg","png","gif","webp","svg","bmp","avif"];
const AUD = ["mp3","flac","wav","ogg","oga","m4a","aac","opus"];
const VID = ["mp4","m4v","webm","mov","mkv","ogv"];
function kind(name) {
  const e = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
  if (IMG.includes(e)) return "image";
  if (AUD.includes(e)) return "audio";
  if (VID.includes(e)) return "video";
  return null;
}
const ICON = { image: "🖼", audio: "🎵", video: "🎬" };

// Build a folder tree from the flat entry list.
const root = { dirs: {}, files: [] };
function ensure(node, parts) {
  for (const p of parts) { node.dirs[p] = node.dirs[p] || { dirs: {}, files: [] }; node = node.dirs[p]; }
  return node;
}
for (const e of DATA.entries) {
  const parts = e.name.split("/").filter(Boolean);
  if (e.dir) { ensure(root, parts); continue; }
  const dir = ensure(root, parts.slice(0, -1));
  dir.files.push({ name: parts[parts.length - 1], i: e.i });
}

// The zip roots entries at the shared folder, so the tree has a single wrapping
// dir; show its contents directly instead of a folder nested inside itself.
let base = root, rootLabel = nameNoZip;
{
  const tops = Object.keys(root.dirs);
  if (tops.length === 1 && root.files.length === 0) { rootLabel = tops[0]; base = root.dirs[tops[0]]; }
}
document.getElementById("title").textContent = rootLabel;
document.title = rootLabel + " — tsync share";

let path = [];
function nodeAt(p) { let n = base; for (const s of p) { n = n.dirs[s]; if (!n) return { dirs: {}, files: [] }; } return n; }

function render() {
  const node = nodeAt(path);
  const cr = document.getElementById("crumbs");
  cr.innerHTML = "";
  const mk = (label, idx) => { const a = document.createElement("a"); a.textContent = label;
    a.onclick = () => { path = path.slice(0, idx); render(); }; return a; };
  cr.appendChild(mk(rootLabel || "root", 0));
  path.forEach((seg, k) => { cr.append(" / "); cr.appendChild(mk(seg, k + 1)); });

  const ul = document.getElementById("list");
  ul.innerHTML = "";
  const dirs = Object.keys(node.dirs).sort((a, b) => a.localeCompare(b));
  const files = node.files.slice().sort((a, b) => a.name.localeCompare(b.name));
  if (!dirs.length && !files.length) { ul.innerHTML = '<div class="empty">Empty folder</div>'; return; }

  for (const d of dirs) {
    const li = document.createElement("li");
    li.innerHTML = '<span class="ico">📁</span>';
    const n = document.createElement("span"); n.className = "name"; n.textContent = d;
    n.onclick = () => { path.push(d); render(); };
    li.appendChild(n); ul.appendChild(li);
  }
  for (const f of files) {
    const k = kind(f.name);
    const li = document.createElement("li");
    const ic = document.createElement("span"); ic.className = "ico"; ic.textContent = ICON[k] || "📄";
    const n = document.createElement("span"); n.className = "name" + (k ? "" : " plain"); n.textContent = f.name;
    if (k) n.onclick = () => preview(f, k);
    const dl = document.createElement("a"); dl.className = "dl"; dl.textContent = "⬇";
    dl.title = "Download"; dl.href = B + "/f/" + f.i + "?dl=1";
    li.append(ic, n, dl); ul.appendChild(li);
  }
}

const pv = document.getElementById("pv");
async function preview(f, k) {
  document.getElementById("pvt").textContent = f.name;
  document.getElementById("pvdl").href = B + "/f/" + f.i + "?dl=1";
  const body = document.getElementById("pvb");
  body.innerHTML = "Loading…";
  if (!pv.open) pv.showModal();
  const r = await fetch(B + "/f/" + f.i + "?json=1");
  if (!r.ok) { body.textContent = "Preview failed (" + r.status + ")"; return; }
  const { url } = await r.json();
  const el = k === "image" ? new Image()
           : Object.assign(document.createElement(k), { controls: true, autoplay: k !== "image" });
  el.src = url;
  body.innerHTML = ""; body.appendChild(el);
}
document.getElementById("pvx").onclick = () => pv.close();
pv.addEventListener("close", () => { document.getElementById("pvb").innerHTML = ""; });

render();
</script>
</body>
</html>
"""
