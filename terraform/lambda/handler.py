"""tsync share Lambda.

Serves a download URL for a file or folder stored in the tsync S3 chunk store.
A GET carries a base64url token = the S3 key of a *share manifest* (written by
`tsync share`). We verify the key is under SHARES_PREFIX, read the manifest, and
on first hit assemble the artifact into a cached `<manifest>.data` object next to
it (file = concatenated chunks; folder = a zip). We then 302-redirect to a
short-lived presigned GET of that object (Function URL responses are size-capped,
so we never stream the body ourselves).

ponytail: ceilings, not solved here. Zip build uses /tmp (10 GB ephemeral) and
the 900 s Lambda timeout, so very large folders won't finish; single files cap at
~80 GB (10,000 multipart parts). Upgrade path when that bites: build on Fargate.
"""

import base64
import json
import os
import time
import zipfile

import boto3
from botocore.exceptions import ClientError

BUCKET = os.environ["BUCKET"]
SHARES_PREFIX = os.environ["SHARES_PREFIX"]  # guard: keys must start with this
PRESIGN_TTL = int(os.environ.get("PRESIGN_TTL", "600"))
CHUNK_READ = 1024 * 1024

s3 = boto3.client("s3")


class ShareError(Exception):
    def __init__(self, code, msg):
        self.code = code
        self.msg = msg


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


def build_file(file_key, chunk_prefix, cache_key):
    m = get_json(file_key)
    if m.get("dirty"):
        raise ShareError(409, "upload in progress, try again shortly")
    if m.get("symlink") is not None:
        raise ShareError(400, "cannot share a symlink directly")
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
        raise ShareError(413, "file too large to assemble")
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
    try:
        s3.upload_file(tmp, BUCKET, cache_key)
    finally:
        os.unlink(tmp)


def build(share, cache_key):
    chunk_prefix = share["chunkPrefix"]
    if share["type"] == "file":
        build_file(share["key"], chunk_prefix, cache_key)
    elif share["type"] == "zip":
        build_zip(share["entries"], chunk_prefix, cache_key)
    else:
        raise ShareError(400, "unknown share type")


def sanitize_filename(name):
    return name.replace('"', "").replace("\\", "").replace("\n", "").replace("\r", "")


def err(code, msg):
    return {"statusCode": code, "headers": {"Content-Type": "text/plain"}, "body": msg + "\n"}


def handler(event, context):
    try:
        # /{token} today; /{token}/... reserved for a future browse/preview route.
        token = event.get("rawPath", "/").lstrip("/").split("/")[0]
        if not token:
            raise ShareError(400, "missing token")
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
        cache_key = manifest_key + ".data"
        if not object_exists(cache_key):
            build(share, cache_key)
        url = s3.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": BUCKET,
                "Key": cache_key,
                "ResponseContentDisposition": 'attachment; filename="%s"'
                % sanitize_filename(share["filename"]),
            },
            ExpiresIn=PRESIGN_TTL,
        )
        return {"statusCode": 302, "headers": {"Location": url}}
    except ShareError as e:
        return err(e.code, e.msg)
