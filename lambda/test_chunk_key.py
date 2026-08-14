"""The two implementations of a chunk key must agree, exactly.

OCaml names a chunk when it uploads it; this Python recomputes that name in the
bucket to decide whether the stored bytes are still what the name says. If the
two ever disagree the failure is not a missed corruption — it is that every
chunk in the store gets filed as corrupt, silently and all at once.

So neither side owns the answer. `tests/unit/hash/hash.ml` prints the keys, dune
holds them in `hash.expected`, and this reads that same file back. One golden
file, checked from both sides, with no third copy to drift.

    pytest lambda/test_chunk_key.py
"""

import pathlib

import pytest

import verify

VECTORS = (
    pathlib.Path(__file__).resolve().parent.parent
    / "tests"
    / "unit"
    / "hash"
    / "hash.expected"
)


def pattern(n):
    """The generator in tests/unit/hash/hash.ml, so the name of a row is enough
    to rebuild the body it was computed over."""
    return bytes(((i * 31) + 7) & 0xFF for i in range(n))


def body_for(name):
    if name == "empty":
        return b""
    if name == "hello":
        return b"hello world"
    if name.startswith("pattern-"):
        return pattern(int(name.split("-", 1)[1]))
    raise AssertionError(f"unknown vector {name!r}")


def vectors():
    rows = []
    for line in VECTORS.read_text().splitlines():
        if not line.endswith(("0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                              "a", "b", "c", "d", "e", "f")):
            continue  # the trailing "ok"
        name, rest = line.split(":", 1)
        h1, h2, key = rest.split()
        rows.append((name, h1, h2, key))
    return rows


ROWS = vectors()


def test_the_golden_file_was_actually_read():
    """A parse that quietly matched nothing would make every test below vacuous:
    zero rows, zero comparisons, green."""
    # Exact, not a floor: a floor two rows below the real count lets rows fail
    # to parse and still pass.
    assert len(ROWS) == 14, [name for name, _, _, _ in ROWS]
    assert any(name == "empty" for name, _, _, _ in ROWS)
    assert any(name == "pattern-8388608" for name, _, _, _ in ROWS)


@pytest.mark.parametrize("name,h1,h2,key", ROWS)
def test_key_matches_ocaml(name, h1, h2, key):
    assert verify.key_of_body([body_for(name)]) == key


@pytest.mark.parametrize("name,h1,h2,key", ROWS)
def test_key_is_the_two_digests_joined(name, h1, h2, key):
    assert key == f"{h1}-{h2}"


@pytest.mark.parametrize("name,h1,h2,key", ROWS)
def test_streamed_matches_one_shot(name, h1, h2, key):
    """The verifier never sees a body whole — the AWS store yields 1 MiB slices —
    so a hash that only agreed when fed in one piece would agree in the test and
    condemn the whole bucket in production."""
    body = body_for(name)
    # Tiny steps only on small bodies: slicing 8 MiB one byte at a time is eight
    # million slices for no coverage the boundary steps do not already give, and
    # it dominated the CI job.
    steps = [s for s in (1, 16, 240) if len(body) <= 4096] + [4096, 1048576]
    for step in steps:
        parts = [body[i:i + step] for i in range(0, len(body), step)] or [b""]
        assert verify.key_of_body(parts) == key


def test_size_comes_from_the_same_pass():
    body = pattern(2600)
    key, size = verify.hash_and_size([body[:1000], body[1000:]])
    assert size == 2600
    assert key == verify.key_of_body([body])
