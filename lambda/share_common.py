"""Cloud-neutral helpers shared by handler.py and the store backends."""

from urllib.parse import quote

CHUNK_READ = 1024 * 1024

# Assembled artifacts and the scratch objects that build them, kept in one
# subtree of SHARES_PREFIX so they can be dropped without touching a share
# manifest. Nothing here is authoritative: every object under it is rebuildable
# from the chunks it was assembled from.
CACHE_DIR = "cache/"


def cache_prefix(shares_prefix):
    return shares_prefix + CACHE_DIR


class ShareError(Exception):
    def __init__(self, code, msg):
        self.code = code
        self.msg = msg


def sanitize_filename(name):
    return name.replace('"', "").replace("\\", "").replace("\n", "").replace("\r", "")


def content_disposition(inline, filename):
    # RFC 5987: HTTP headers are ASCII, so non-ASCII names (accents, NFD combining
    # marks) go in filename* as percent-encoded UTF-8, with an ASCII filename
    # fallback. Putting raw UTF-8 in filename="..." makes the backend reject it.
    disp = "inline" if inline else "attachment"
    ascii_name = sanitize_filename(filename).encode("ascii", "replace").decode("ascii")
    return "%s; filename=\"%s\"; filename*=UTF-8''%s" % (disp, ascii_name, quote(filename, safe=""))
