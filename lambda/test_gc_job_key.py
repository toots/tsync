"""The two implementations of a delete request's key must agree, exactly.

OCaml composes the key when a collection hands its deletes over; this Python
parses it back to learn which domain is asking, and refuses to delete anything
outside that domain's chunks. Disagree and the failure is quiet: every request
is ignored, the copy is never emptied, and the only thing that ever says so is a
later `tsync gc --status`.

So neither side owns the answer. `tests/unit/gc_job/gc_job.ml` prints the keys,
dune holds them in `gc_job.expected`, and this reads that same file back. One
golden file, checked from both sides, with no third copy to drift.

    pytest lambda/test_gc_job_key.py
"""

import pathlib

import pytest

import verify

VECTORS = (
    pathlib.Path(__file__).resolve().parent.parent
    / "tests"
    / "unit"
    / "gc_job"
    / "gc_job.expected"
)


def rows(kind):
    """The `kind|...` rows of the golden file, already split."""
    found = []
    for line in VECTORS.read_text().splitlines():
        parts = line.split("|")
        if parts[0] == kind:
            found.append(parts[1:])
    return found


def test_the_golden_file_is_there_and_populated():
    """A vector file that stopped being produced would make every test below
    pass over nothing."""
    assert VECTORS.exists(), VECTORS
    assert len(rows("job")) >= 12
    assert len(rows("prefix")) >= 4
    assert len(rows("not-a-job")) >= 5


@pytest.mark.parametrize("domain,run,shard,key", rows("job"))
def test_a_composed_key_parses_back_to_its_domain(domain, run, shard, key):
    assert verify.gc_job_domain(key) == domain


@pytest.mark.parametrize("domain,prefix", rows("prefix"))
def test_the_prefix_is_the_one_python_lists_under(domain, prefix):
    """The client lists this prefix to report what is outstanding, and the
    notification filter has to cover it, so both sides must build it the same."""
    assert prefix.startswith(verify.GC_JOBS_ROOT)
    assert prefix == f"{verify.GC_JOBS_ROOT}{domain}/"


@pytest.mark.parametrize("key", [row[0] for row in rows("not-a-job")])
def test_what_is_not_a_request_is_refused(key):
    """A chunk reaching the delete path is the one thing that must never
    happen, so the keys OCaml says are not requests are checked here too."""
    assert verify.gc_job_domain(key) is None


@pytest.mark.parametrize("domain,run,shard,key", rows("job"))
def test_a_request_is_never_mistaken_for_a_chunk(domain, run, shard, key):
    assert verify.marker_key(key) is None
    assert verify.job_target(key) is None
