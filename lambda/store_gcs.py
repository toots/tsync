"""Google Cloud Storage backend for the share handler.

Same interface as store_aws. Assembly uses GCS `compose` (server-side, no /tmp):
up to 32 source objects concatenate into one in a single call; more than 32 are
composed in tiers through temporary objects that are cleaned up afterwards.
"""

import os
import uuid
from datetime import timedelta

from google.cloud import storage
from google.cloud.exceptions import NotFound

from share_common import ShareError, content_disposition

COMPOSE_MAX = 32  # GCS caps a single compose at 32 source objects


class Store:
    def __init__(self):
        self.bucket_name = os.environ["BUCKET"]
        self.shares_prefix = os.environ["SHARES_PREFIX"]
        self.presign_ttl = int(os.environ.get("PRESIGN_TTL", "600"))
        self.client = storage.Client()
        self.bucket = self.client.bucket(self.bucket_name)

    def get_bytes(self, key):
        try:
            return self.bucket.blob(key).download_as_bytes()
        except NotFound:
            raise FileNotFoundError(key)

    def exists(self, key):
        return self.bucket.blob(key).exists()

    def put_bytes(self, key, data):
        self.bucket.blob(key).upload_from_string(data)

    def list_keys(self, prefix):
        for blob in self.client.list_blobs(self.bucket_name, prefix=prefix):
            yield blob.name

    def read_chunk(self, key):
        # Chunks are bounded (~8 MiB), so a single download is fine.
        yield self.bucket.blob(key).download_as_bytes()

    def upload_file(self, local, key):
        self.bucket.blob(key).upload_from_filename(local)

    def signed_url(self, key, filename, content_type=None, inline=False):
        # V4 signing. On Cloud Functions the runtime has no raw private key, so
        # the client signs via the IAM SignBlob API — the function SA needs
        # roles/iam.serviceAccountTokenCreator on itself (see terraform).
        return self.bucket.blob(key).generate_signed_url(
            version="v4",
            expiration=timedelta(seconds=self.presign_ttl),
            response_disposition=content_disposition(inline, filename),
            response_type=content_type,
        )

    def _compose(self, keys, dest_key):
        """Compose <= COMPOSE_MAX source objects into dest_key."""
        dest = self.bucket.blob(dest_key)
        try:
            dest.compose([self.bucket.blob(k) for k in keys])
        except NotFound:
            raise ShareError(502, "a data block of this file is missing on the backend")
        return dest

    def assemble(self, chunk_keys, dest_key):
        """Concatenate [chunk_keys] (in order) into dest_key via compose,
        tiering through temp objects when there are more than COMPOSE_MAX."""
        temps = []
        try:
            keys = list(chunk_keys)
            while len(keys) > COMPOSE_MAX:
                next_keys = []
                for i in range(0, len(keys), COMPOSE_MAX):
                    group = keys[i:i + COMPOSE_MAX]
                    if len(group) == 1:
                        next_keys.append(group[0])
                        continue
                    tmp = "%scompose-tmp/%s-%d" % (self.shares_prefix, uuid.uuid4().hex, i)
                    self._compose(group, tmp)
                    temps.append(tmp)
                    next_keys.append(tmp)
                keys = next_keys
            self._compose(keys, dest_key)
        finally:
            for tmp in temps:
                try:
                    self.bucket.blob(tmp).delete()
                except Exception:
                    pass
