"""The reader agrees with the OCaml writer: it decodes the byte-exact example of
spec 02 §2.6, which tests/remote/codec_test.expected pins on the OCaml side."""

import manifest

EXAMPLE = bytes.fromhex(
    "74 73 79 6e 63 6d 30 34 0b 00 00 00 00 00 00 00"
    "00 a5 fb 97 82 b8 69 18 00 80 e9 2f 2e 39 69 18"
    "00 00 80 00 01 00 00 00 09 00 00 00 00 00 00 00"
    "64 39 34 62 34 65 39 36 32 36 66 64 63 39 63 31"
    "66 33 66 36 64 37 39 33 63 61 31 65 61 34 32 34"
    "68 65 6c 6c 6f 2e 74 78 74 64 34 34 37 62 31 65"
    "61 34 30 65 36 39 38 38 62 2d 62 37 61 65 62 35"
    "32 61 31 30 66 64 61 66 32 64".replace(" ", ""))


def test_spec_example():
    m = manifest.Manifest(EXAMPLE)
    assert m.size == 11
    assert m.mtime == 1_759_140_000_500_000_000
    assert m.created == 1_759_000_000_000_000_000
    assert m.chunk_size == 8388608
    assert m.count == 1
    assert m.name == "hello.txt"
    assert m.h1 == "d94b4e9626fdc9c1"
    assert list(m.keys()) == ["d447b1ea40e6988b-b7aeb52a10fdaf2d"]


def test_spec_example_reencodes():
    m = manifest.Manifest(EXAMPLE)
    assert manifest.encode(
        name=m.name, size=m.size, chunk_size=m.chunk_size, mtime=m.mtime,
        created=m.created, h1=m.h1, h2=m.h2, symlink=None,
        keys=list(m.keys())) == EXAMPLE
