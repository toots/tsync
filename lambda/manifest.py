"""Reading a file manifest body.

A manifest is a fixed-layout header followed by a flat run of chunk keys. Every
field sits at a known offset and chunk i's key is a slice at a computed one, so
there is no parsing beyond a struct unpack — which matters at the sizes these
reach: a 32 GB file at a 1 MiB chunk size carries 31,230 chunk keys.

This mirrors lib/object/chunk_table.ml. The two must agree byte for byte; the
layout is documented in both.

Folder markers are a different thing and stay JSON — they are one small object
per directory, and telling them apart from a file manifest is what MAGIC is for.

Layout (little-endian, offsets in bytes):

    0   8   magic b"tsyncm03"
    8   8   size       uint64  logical file size
    16  8   mtime      double  IEEE bits
    24  4   chunk_size uint32
    28  4   count      uint32  chunk keys that follow
    32  4   name_len   uint32
    36  4   link_len   uint32  0 for a regular file
    40  16  h1                 whole-file digest, hex
    56  16  h2
    72      name bytes, then symlink target bytes, then count * 33 chunk keys

Every variable-length field is length-prefixed, so nothing needs escaping: a
leaf name is an arbitrary byte string.
"""

import struct

MAGIC = b"tsyncm03"
HEADER_BYTES = 72

# A chunk key is "<h1>-<h2>", two 16-character hex digests, stored verbatim.
KEY_BYTES = 33

_HEADER = struct.Struct("<8sQdIIII16s16s")


class Malformed(Exception):
    """A body that is truncated, mistyped, or whose header disagrees with its
    actual length."""


def is_manifest(body):
    """Whether [body] is a file manifest rather than a folder marker."""
    return body[:8] == MAGIC


class Manifest:
    __slots__ = ("size", "mtime", "chunk_size", "count", "name", "symlink",
                 "h1", "h2", "_body", "_keys_at")

    def __init__(self, body):
        if len(body) < HEADER_BYTES:
            raise Malformed("short manifest")
        (magic, size, mtime, chunk_size, count, name_len, link_len, h1,
         h2) = _HEADER.unpack_from(body, 0)
        if magic != MAGIC:
            raise Malformed("bad magic")
        keys_at = HEADER_BYTES + name_len + link_len
        expected = keys_at + count * KEY_BYTES
        if len(body) != expected:
            raise Malformed(
                "body is %d bytes, header describes %d" % (len(body), expected))
        self.size = size
        self.mtime = mtime
        self.chunk_size = chunk_size
        self.count = count
        self.h1 = h1.decode("ascii")
        self.h2 = h2.decode("ascii")
        self.name = body[HEADER_BYTES:HEADER_BYTES + name_len].decode(
            "utf-8", "surrogateescape")
        self.symlink = (
            body[HEADER_BYTES + name_len:keys_at].decode("utf-8", "surrogateescape")
            if link_len else None)
        self._body = body
        self._keys_at = keys_at

    def key(self, i):
        """Chunk i's key, "<h1>-<h2>"."""
        off = self._keys_at + i * KEY_BYTES
        return self._body[off:off + KEY_BYTES].decode("ascii")

    def keys(self):
        """Every chunk key, in index order."""
        return [self.key(i) for i in range(self.count)]

    def chunk_len(self, i):
        """Bytes chunk i holds: chunk_size for every chunk but the last.
        Derived from the header rather than stored per chunk."""
        if self.chunk_size <= 0:
            return 0
        return max(0, min(self.chunk_size, self.size - i * self.chunk_size))


def encode(name, size, chunk_size, mtime, h1, h2, symlink, keys):
    """Serialize a body. The Lambda only reads them; this exists so tests can
    build one, and so the layout has a single executable description on this
    side too."""
    name_b = name.encode("utf-8", "surrogateescape")
    link_b = (symlink or "").encode("utf-8", "surrogateescape")
    for what, s in (("h1", h1), ("h2", h2)):
        if len(s) != 16:
            raise ValueError("%s is %r" % (what, s))
    for k in keys:
        if len(k) != KEY_BYTES:
            raise ValueError("chunk key %r" % (k,))
    return (
        _HEADER.pack(MAGIC, size, mtime, chunk_size, len(keys), len(name_b),
                     len(link_b), h1.encode("ascii"), h2.encode("ascii"))
        + name_b
        + link_b
        + b"".join(k.encode("ascii") for k in keys)
    )
