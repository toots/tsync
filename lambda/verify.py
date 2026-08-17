"""Hold each stored chunk against its own name.

The key is XXH3-64 seeded 0 and 1, sixteen lowercase hex each joined by a dash,
over bodies stored raw (lib/naming/chunk_layout.ml).

The bucket's object-created event runs this one object at a time, so there is
no cursor and no pagination, and only marker keys ever leave the cloud.

A marker is deleted before the body is read, unlike the OCaml side which checks
first: object events are at-least-once and unordered, and a marker left on a
good object costs one extra upload where a good-looking marker on bad bytes is
recoverable by nothing.
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

ROOT = "tsync/"  # lib/config/parsing/conf_parsing.ml
CHUNKS_SEG = "/chunks/"
# Beside the domains rather than inside one, with the domain as their first
# segment: one literal prefix then covers every domain, which is what a
# notification filter and an IAM condition both need — neither takes a wildcard,
# and Google's conditions offer only startsWith.
CORRUPTED_ROOT = ROOT + "corrupted/"
JOBS_ROOT = ROOT + "verify-jobs/"
GC_JOBS_ROOT = ROOT + "gc-jobs/"
FANOUT = 3  # lib/naming/chunk_layout.ml
KEY_HEX = 16  # lib/utils/xxhash/xxhash.ml, hex_length

_store = None


def empty_result():
    """What every entry point answers with when there was nothing to do. One
    shape, so a caller adding the counts needs no default for a missing key."""
    return {"checked": 0, "corrupt": 0, "deleted": 0}


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
    neither `tsync/corrupted/` nor `chunks.from/` spells that segment.

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
    root = key[:cut]                       # tsync/<domain>
    _, sep, domain = root.partition("/")
    if not sep or not domain:
        return None
    return f"{CORRUPTED_ROOT}{domain}/{rest}"


def chunk_prefix(domain):
    """Where a domain's chunks live. Composed here rather than at each place
    that needs it, matching Conf_parsing.chunk_prefix on the client."""
    return f"{ROOT}{domain}{CHUNKS_SEG}"


def job_target(key):
    """The chunk prefix a whole-store request names, or None when [key] is not
    one.

    Requests live at `verify-jobs/<domain>/<shard>` — top level, with the domain
    inside rather than around. One literal prefix therefore reaches every
    domain's, so the notification that delivers them needs no list of domain
    names: such a list has no safe default and fails silently, a name matching
    nothing deploying a trigger that never fires.

    A request is an empty object the client writes; the bucket's own notification
    delivers it here. So a sweep is the same function on the same trigger doing
    the same per-chunk check — there is no second path to keep in step.
    """
    if not key.startswith(JOBS_ROOT):
        return None
    rest = key[len(JOBS_ROOT):]
    domain, sep, shard = rest.rpartition("/")
    if not sep or not domain or not is_shard_name(shard):
        return None
    return f"{chunk_prefix(domain)}{shard}/"


def gc_job_domain(key):
    """The domain a delete request belongs to, or None when [key] is not one.

    Requests live at `gc-jobs/<domain>/<run>/<shard>`, top level with the domain
    inside, so one literal prefix reaches every domain the way JOBS_ROOT does.
    The run is in the name because a later collection reaching the same shard
    would otherwise overwrite one an earlier collection left unconsumed, losing
    both its keys and the evidence that it stuck.
    """
    if not key.startswith(GC_JOBS_ROOT):
        return None
    head, sep, shard = key[len(GC_JOBS_ROOT):].rpartition("/")
    if not sep or not is_shard_name(shard):
        return None
    domain, sep, run = head.rpartition("/")
    if not sep or not domain or not run:
        return None
    return domain


def may_delete(key, domain):
    """Whether a request from [domain] may name [key].

    This function can delete any chunk in the bucket, so a request body is the
    only thing choosing what goes — it is checked here rather than trusted, and
    against the requesting domain, so one domain's collection cannot reach into
    another's. `marker_key` is the shape test: it answers for exactly
    `<root>/chunks/<shard>/<chunk-key>` and for nothing else, which is why a
    marker, a manifest and anything under `chunks.from/` all fail it.
    """
    return marker_key(key) is not None and key.startswith(chunk_prefix(domain))


def existing_markers(st, domain, keys):
    """The markers actually accusing [keys], of the ones that could.

    Deleting a derived marker unseen doubles what a request costs, to remove
    something a healthy store has none of -- and it was a thousand pointless
    deletes a batch that rate-limited a real bucket. One listing answers for the
    whole request instead.
    """
    wanted = {m for m in (marker_key(k) for k in keys) if m}
    if not wanted:
        return []
    return [k for k in st.list_keys(f"{CORRUPTED_ROOT}{domain}/") if k in wanted]


def run_gc_job(st, key):
    """Drop the chunks a request names, and the markers accusing them.

    A marker is not named in the request: where one lives is read off the chunk
    key here, exactly as it is on the client, so the request stays the size the
    collection meant it to be.

    Deleted last, and only when every key the store was asked for went: a bulk
    delete answers success while refusing keys inside the body, and dropping the
    request on one of those would strand chunks nothing will ever name again. A
    key this refuses on sight is not that case — no retry would make it
    permitted — so it is logged and the request still goes.
    """
    domain = gc_job_domain(key)
    if domain is None:
        return None
    try:
        body = st.get_bytes(key).decode()
    except FileNotFoundError:
        # Object events are at-least-once: a redelivery of a consumed request.
        return empty_result()
    wanted = [line.strip() for line in body.split("\n")]
    wanted = [k for k in wanted if k]
    keys = [k for k in wanted if may_delete(k, domain)]
    for k in wanted:
        if k not in keys:
            print(f"gc job {key}: refused {k!r}")
    refused = st.delete_many(keys + existing_markers(st, domain, keys))
    if refused:
        print(
            f"gc job {key}: {len(refused)} object(s) not deleted, first "
            f"{refused[0]}: leaving the request in place"
        )
        return empty_result()
    st.delete(key)
    print(f"gc job {key}: {len(keys)} chunk(s) dropped")
    return {"checked": 0, "corrupt": 0, "deleted": len(keys)}


def verify_shard(st, key):
    """Check every chunk in the shard a request names, then drop the request.

    Deleted last, so a run that dies partway leaves the request in place: it is
    then visible to whoever asks why the sweep never finished, and re-queueing is
    what retries it. Deleting first would lose that.
    """
    prefix = job_target(key)
    if prefix is None:
        return None
    shard = key.rsplit("/", 1)[-1]
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
    """One object-created event, whichever kind. A chunk is checked; a sweep
    request checks the shard it names; a delete request drops the chunks it
    names; anything else is not ours."""
    if gc_job_domain(key) is not None:
        return run_gc_job(st, key)
    if job_target(key) is not None:
        return verify_shard(st, key)
    result = verify_object(st, key)
    if result is None:
        return None
    return {"checked": 1, "corrupt": 0 if result else 1}


def handler(event, context):
    """AWS entry point: an s3:ObjectCreated:* notification."""
    checked = 0
    bad = 0
    dropped = 0
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
        dropped += result.get("deleted", 0)
    return {"checked": checked, "corrupt": bad, "deleted": dropped}


def pubsub_attributes(event):
    """The attributes of a Pub/Sub message, however the runtime chose to hand it
    over.

    Two conventions reach the same function. A CloudEvent one passes an object
    whose `.data` wraps the message under `message`; the older background one
    passes the message itself as a plain dict, alongside a context argument. The
    functions framework picks between them from a signature type nothing in the
    deployment sets explicitly, so the entry point takes whichever arrives rather
    than depending on that choice.
    """
    data = getattr(event, "data", event)
    if not isinstance(data, dict):
        return {}
    message = data.get("message", data)
    if not isinstance(message, dict):
        return {}
    return message.get("attributes") or {}


def gcp_verify(event, context=None):
    """GCP entry point: an OBJECT_FINALIZE notification delivered over Pub/Sub.

    Pub/Sub rather than an Eventarc storage trigger, which has no prefix filter
    and would fire this on every manifest and journal write in the bucket.

    [context] is the second argument of the background convention, unused: the
    message attributes carry the object name, and the delivery's own identifiers
    say nothing about which chunk to check.
    """
    key = pubsub_attributes(event).get("objectId")
    if not key:
        return empty_result()
    return verify_key(store(), key) or empty_result()
