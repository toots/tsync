"""Hold each stored chunk against its own name.

A chunk's key is the hash of its bytes -- XXH3-64 seeded 0 and 1, sixteen
lowercase hex each, joined by a dash (lib/naming/chunk_layout.ml). Bodies are
stored raw, so a chunk object can be checked with nothing but itself: hash what
is there and compare it to the name it arrived under. What fails is filed under
the domain's `corrupted/` prefix, where any client lists it.

The bucket's own object-created event runs this, one object per invocation, so
there is no cursor and no pagination. The client never calls it, and never
downloads a body to check one: only marker keys ever leave the cloud.

Order is delete-then-check, unlike the OCaml side which checks first. Object
events are at-least-once and unordered, so a marker must never outlive the write
that fixed the chunk; clearing first means the worst a reordered pair can do is
leave a marker on a good object, which costs exactly one extra upload -- the
client reads it as absent, re-uploads, and that event clears it. The reverse
mistake, a good-looking marker on bad bytes, is not recoverable by anything.
"""

import json
import os
import sys
import time
import traceback
from urllib.parse import unquote_plus

# Appended, not inserted: on GCP the buildpack installs xxhash from
# requirements.txt for the right interpreter, and that must win over the
# aarch64 wheel vendored here for Lambda.
sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor"))

import xxhash  # noqa: E402

CHUNKS_SEG = "/chunks/"
CORRUPTED_SEG = "/corrupted/"
JOBS_SEG = "/verify-jobs/"
FANOUT = 3  # lib/naming/chunk_layout.ml
KEY_HEX = 16  # lib/utils/xxhash/xxhash.ml, hex_length

_store = None


def store():
    """Imported and built on first use, so importing this module costs neither
    credentials nor a cloud SDK. That is what lets the key-agreement test — the
    one that matters most here — run against the pure helpers alone."""
    global _store
    if _store is None:
        if os.environ.get("STORE", "aws") == "gcs":
            from store_gcs import Store
        else:
            from store_aws import Store
        _store = Store()
    return _store


def _is_hex(s):
    return len(s) == KEY_HEX and all(c in "0123456789abcdef" for c in s)


def is_chunk_key(name):
    h1, sep, h2 = name.partition("-")
    return bool(sep) and _is_hex(h1) and _is_hex(h2)


def is_shard_name(name):
    return len(name) == FANOUT and all(c in "0123456789abcdef" for c in name)


def hash_and_size(parts):
    """The key a body belongs under and how many bytes it was, from an iterable
    of byte slices.

    Streamed rather than taken whole: the AWS store yields 1 MiB at a time, and a
    chunk size is only a default. Two states over one pass, so the object is read
    once and the size costs no second read. Formatted `%016x` unsigned, matching
    OCaml's `%016Lx`.
    """
    h1 = xxhash.xxh3_64(seed=0)
    h2 = xxhash.xxh3_64(seed=1)
    size = 0
    for part in parts:
        h1.update(part)
        h2.update(part)
        size += len(part)
    return f"{h1.intdigest():016x}-{h2.intdigest():016x}", size


def key_of_body(parts):
    """Just the key. What the OCaml calls Chunk_layout.key_of_body, and what the
    shared golden vectors in tests/unit/hash are checked against."""
    return hash_and_size(parts)[0]


def marker_key(key):
    """Where a marker for the chunk object at [key] belongs, or None when [key]
    names something else.

    Matching `/chunks/` exactly is what keeps a marker from earning one of its
    own, and leaves alone a chunk in the space a collection is moving out of:
    neither `corrupted/` nor `chunks.from/` spells that segment. The bucket
    notification's prefix filter says the same thing; both are kept because a
    filter is configuration and this is not.

    Membership is the prefix and never the shape of the name. A manifest is filed
    under the hash of its own file name, so it is spelled exactly like a chunk
    key and would fail a hash-of-body check every time.
    """
    cut = key.rfind(CHUNKS_SEG)
    if cut < 0:
        return None
    rest = key[cut + len(CHUNKS_SEG):]
    shard, sep, leaf = rest.partition("/")
    if not sep or not is_shard_name(shard) or not is_chunk_key(leaf):
        return None
    return key[:cut] + CORRUPTED_SEG + rest


def job_shard(key):
    """The shard a whole-store request names, or None when [key] is not one.

    A request is an empty object under `verify-jobs/`, written by the client one
    per shard; the bucket's own notification delivers it here. So a sweep is the
    same function on the same trigger doing the same per-chunk check — there is
    no second path to keep in step, and nothing to run but what already runs on
    every upload.
    """
    cut = key.rfind(JOBS_SEG)
    if cut < 0:
        return None
    shard = key[cut + len(JOBS_SEG):]
    return shard if is_shard_name(shard) else None


def verify_shard(st, key):
    """Check every chunk in the shard a request names, then drop the request.

    Deleted last, so a run that dies partway leaves the request in place: it is
    then visible to whoever asks why the sweep never finished, and re-queueing is
    what retries it. Deleting first would lose that.
    """
    shard = job_shard(key)
    if shard is None:
        return None
    prefix = key[: key.rfind(JOBS_SEG)] + CHUNKS_SEG + shard + "/"
    checked = bad = 0
    for chunk in st.list_keys(prefix):
        result = verify_object(st, chunk)
        if result is None:
            continue
        checked += 1
        bad += 0 if result else 1
    st.delete(key)
    print(f"shard {shard}: {checked} chunk(s) checked, {bad} corrupt")
    return {"checked": checked, "corrupt": bad}


def verify_object(st, key):
    """Check one chunk object. Returns True when it is what its name says, False
    when it is not, and None when [key] does not name a chunk (nothing read)."""
    marker = marker_key(key)
    if marker is None:
        return None
    # Before reading: see the module docstring on ordering.
    st.delete(marker)
    computed, size = hash_and_size(st.read_chunk(key))
    expected = key.rsplit("/", 1)[-1]
    if computed == expected:
        return True
    # Same fields as lib/naming/corruption_marker.ml; the key is the finding and
    # these are for whoever reads the report next.
    st.put_bytes(
        marker,
        json.dumps({"computed": computed, "size": size, "at": time.time()}).encode(),
    )
    print(f"chunk {expected} hashed to {computed}: filed {marker}")
    return False


def _keys_from_event(event):
    """S3 puts them under Records[].s3.object.key, URL-encoded."""
    for record in event.get("Records", []):
        s3 = record.get("s3")
        if s3:
            yield unquote_plus(s3["object"]["key"])


def verify_key(st, key):
    """One object-created event, whichever kind. A chunk is checked; a request
    sweeps the shard it names; anything else is not ours."""
    if job_shard(key) is not None:
        return verify_shard(st, key)
    result = verify_object(st, key)
    if result is None:
        return None
    return {"checked": 1, "corrupt": 0 if result else 1}


def handler(event, context):
    """AWS entry point: an s3:ObjectCreated:* notification."""
    checked = 0
    bad = 0
    for key in _keys_from_event(event):
        try:
            result = verify_key(store(), key)
        except Exception:
            # One bad object must not abandon the rest of the batch, and a raise
            # here would have S3 redeliver the whole notification.
            traceback.print_exc()
            continue
        if result is None:
            continue
        checked += result["checked"]
        bad += result["corrupt"]
    return {"checked": checked, "corrupt": bad}


def gcp_verify(cloud_event):
    """GCP entry point: an OBJECT_FINALIZE notification delivered over Pub/Sub.

    Pub/Sub rather than an Eventarc storage trigger, which has no prefix filter
    and would fire this on every manifest and journal write in the bucket.
    """
    message = (cloud_event.data or {}).get("message", {})
    attributes = message.get("attributes") or {}
    key = attributes.get("objectId")
    if not key:
        return {"checked": 0, "corrupt": 0}
    return verify_key(store(), key) or {"checked": 0, "corrupt": 0}
