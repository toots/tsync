"""S3 storage backend for the share handler.

Wraps every storage operation the handler needs behind a plain object, so the
handler stays cloud-agnostic. Assembly uses server-side chunk copy (no /tmp):
a single chunk is a copy_object, many chunks a concurrent multipart upload-copy.
"""

import concurrent.futures
import os

import boto3
from botocore.exceptions import ClientError

from share_common import CHUNK_READ, ShareError, content_disposition


def _chunk_copy_error(e):
    """Translate a boto error from copying a chunk into a clean ShareError, or
    None to let it propagate (surfaced as a logged 500). A file that lists a
    chunk which is absent — or has aged into cold storage — is a data problem,
    not a server bug."""
    code = e.response.get("Error", {}).get("Code", "")
    if code in ("NoSuchKey", "NoSuchBucket", "404"):
        return ShareError(502, "a data block of this file is missing on the backend")
    if code == "InvalidObjectState":
        return ShareError(503, "file is in cold storage (Glacier); try again later")
    return None


class Store:
    def __init__(self):
        self.bucket = os.environ["BUCKET"]
        self.presign_ttl = int(os.environ.get("PRESIGN_TTL", "600"))
        self.s3 = boto3.client("s3")

    def get_bytes(self, key):
        try:
            return self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read()
        except ClientError as e:
            if e.response["Error"]["Code"] in ("NoSuchKey", "404", "NoSuchBucket"):
                raise FileNotFoundError(key)
            raise

    def exists(self, key):
        try:
            self.s3.head_object(Bucket=self.bucket, Key=key)
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
                return False
            raise

    def put_bytes(self, key, data):
        self.s3.put_object(Bucket=self.bucket, Key=key, Body=data)

    def list_keys(self, prefix):
        paginator = self.s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=self.bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                yield obj["Key"]

    def read_chunk(self, key):
        body = self.s3.get_object(Bucket=self.bucket, Key=key)["Body"]
        for buf in iter(lambda: body.read(CHUNK_READ), b""):
            yield buf

    def upload_file(self, local, key):
        self.s3.upload_file(local, self.bucket, key)

    def signed_url(self, key, filename, content_type=None, inline=False):
        params = {
            "Bucket": self.bucket,
            "Key": key,
            "ResponseContentDisposition": content_disposition(inline, filename),
        }
        if content_type:
            params["ResponseContentType"] = content_type
        return self.s3.generate_presigned_url(
            "get_object", Params=params, ExpiresIn=self.presign_ttl
        )

    def assemble(self, chunk_keys, dest_key):
        """Concatenate [chunk_keys] (in order) into dest_key by server-side copy.
        Caller has already applied the size / count guards."""
        try:
            if len(chunk_keys) == 1:
                self.s3.copy_object(
                    Bucket=self.bucket, Key=dest_key,
                    CopySource={"Bucket": self.bucket, "Key": chunk_keys[0]},
                )
                return
            upload_id = self.s3.create_multipart_upload(
                Bucket=self.bucket, Key=dest_key
            )["UploadId"]
            try:
                # Part copies are independent server-side operations, so run them
                # concurrently — a large file assembles in seconds instead of
                # thousands of sequential round-trips.
                def copy_part(item):
                    n, key = item
                    r = self.s3.upload_part_copy(
                        Bucket=self.bucket, Key=dest_key, UploadId=upload_id,
                        PartNumber=n,
                        CopySource={"Bucket": self.bucket, "Key": key},
                    )
                    return {"ETag": r["CopyPartResult"]["ETag"], "PartNumber": n}

                with concurrent.futures.ThreadPoolExecutor(max_workers=32) as ex:
                    parts = list(ex.map(copy_part, enumerate(chunk_keys, start=1)))
                parts.sort(key=lambda p: p["PartNumber"])
                self.s3.complete_multipart_upload(
                    Bucket=self.bucket, Key=dest_key, UploadId=upload_id,
                    MultipartUpload={"Parts": parts},
                )
            except Exception:
                self.s3.abort_multipart_upload(
                    Bucket=self.bucket, Key=dest_key, UploadId=upload_id
                )
                raise
        except ClientError as e:
            raise (_chunk_copy_error(e) or e)
