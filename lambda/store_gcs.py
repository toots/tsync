"""Google Cloud Storage backend for the share handler.

Same interface as store_aws. Assembly uses GCS `compose` (server-side, no /tmp):
up to 32 source objects concatenate into one in a single call; more than 32 are
composed in tiers through temporary objects that are cleaned up afterwards, each
tier running its groups concurrently the way store_aws runs its part copies.
"""

import concurrent.futures
import os
import uuid
from datetime import timedelta

import google.auth
import google.auth.transport.requests
from google.cloud import storage
from google.cloud.exceptions import NotFound

from share_common import ShareError, cache_prefix, content_disposition

COMPOSE_MAX = 32  # GCS caps a single compose at 32 source objects


class Store:
    def __init__(self):
        self.bucket_name = os.environ["BUCKET"]
        self.cache_prefix = cache_prefix(
            os.environ.get("SHARES_PREFIX", "tsync/shares/")
        )
        self.presign_ttl = int(os.environ.get("PRESIGN_TTL", "600"))
        self.client = storage.Client()
        self.bucket = self.client.bucket(self.bucket_name)
        # Resolved on first signature; tests against the emulator have no ADC.
        self.credentials = None

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
        # V4 signing. On Cloud Functions the runtime credentials are a bare token
        # with no private key, so signing must go through the IAM SignBlob API.
        # generate_signed_url only takes that path when handed an explicit SA
        # email + live access token; without them it demands a local key and
        # raises AttributeError. The SA needs roles/iam.serviceAccountTokenCreator
        # on itself (see terraform).
        if self.credentials is None:
            self.credentials, _ = google.auth.default()
        if not self.credentials.valid:
            # Also what populates service_account_email from the metadata server.
            self.credentials.refresh(google.auth.transport.requests.Request())
        return self.bucket.blob(key).generate_signed_url(
            version="v4",
            expiration=timedelta(seconds=self.presign_ttl),
            response_disposition=content_disposition(inline, filename),
            response_type=content_type,
            service_account_email=self.credentials.service_account_email,
            access_token=self.credentials.token,
        )

    def _compose(self, keys, dest_key):
        """Compose <= COMPOSE_MAX source objects into dest_key."""
        dest = self.bucket.blob(dest_key)
        try:
            dest.compose([self.bucket.blob(k) for k in keys])
        except NotFound:
            raise ShareError(502, "a data block of this file is missing on the backend")
        return dest

    def _delete_quietly(self, key):
        try:
            self.bucket.blob(key).delete()
        except Exception:
            pass

    def assemble(self, chunk_keys, dest_key):
        """Concatenate [chunk_keys] (in order) into dest_key via compose,
        tiering through temp objects when there are more than COMPOSE_MAX.

        A tier's groups are independent server-side operations, so they run
        concurrently: a tier costs one compose rather than one per group, which
        is the difference between seconds and minutes on a file with hundreds of
        chunks. Only the tiers themselves are sequential, each needing the one
        below it to exist."""
        temps = []
        try:
            keys = list(chunk_keys)
            while len(keys) > COMPOSE_MAX:
                groups = [
                    keys[i:i + COMPOSE_MAX]
                    for i in range(0, len(keys), COMPOSE_MAX)
                ]
                # A group of one is already the result it would compose to.
                plan = [
                    (g, "" if len(g) == 1 else
                     "%scompose-tmp/%s" % (self.cache_prefix, uuid.uuid4().hex))
                    for g in groups
                ]
                pending = [(g, tmp) for g, tmp in plan if tmp]
                # Recorded before the composes run: one failing mid-tier still
                # leaves the others to clean up.
                temps.extend(tmp for _, tmp in pending)
                self._parallel(lambda item: self._compose(*item), pending)
                keys = [tmp or g[0] for g, tmp in plan]
            self._compose(keys, dest_key)
        finally:
            self._parallel(self._delete_quietly, temps)

    @staticmethod
    def _parallel(fn, items):
        """Run [fn] over [items], propagating the first exception. [map] is lazy,
        so the result has to be consumed for that to happen."""
        if not items:
            return
        with concurrent.futures.ThreadPoolExecutor(max_workers=COMPOSE_MAX) as ex:
            list(ex.map(fn, items))
