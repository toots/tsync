# Vendored wheels

`verify.py` hashes stored chunks with XXH3-64, which is not in the standard
library. GCP installs it from `../requirements.txt` — the Cloud Functions gen2
buildpack reads that file — but AWS Lambda does not: the deployment zip is a
plain `archive_file` over this directory tree (`terraform/main.tf`) with no pip
step, and the runtime ships only boto3. So the extension is committed here.

That makes the wheel architecture-specific, which is why
`terraform/modules/store-s3/verify.tf` pins `architectures = ["arm64"]` on the
verify function. The share function travels in the same zip but never imports
`xxhash`, so the file is inert there and it is left unpinned — pinning it would
force an architecture migration on every existing deployment to buy nothing.

## Regenerating

Match the Lambda runtime's Python version (`python3.13`) and architecture:

```sh
pip download xxhash --only-binary=:all: --no-deps \
    --platform manylinux2014_aarch64 --python-version 3.13 -d /tmp/x
cd lambda/vendor && unzip -o /tmp/x/xxhash-*.whl
rm -rf xxhash-*.dist-info          # installer metadata, unused at runtime
strip --strip-unneeded xxhash/_xxhash.cpython-313-*.so
```

Stripping is what keeps this at ~200 KB rather than 1.3 MB; `PyInit__xxhash` is
a dynamic symbol and survives it. Confirm the result actually loads, since a
broken hash here does not under-report corruption — it files *every* chunk in
the store as corrupt:

```sh
podman run --rm -v "$PWD/lambda/vendor:/v:ro,z" docker.io/library/python:3.13-slim \
    python -c "import sys; sys.path.insert(0,'/v'); import xxhash;
h=xxhash.xxh3_64(seed=0); h.update(b''); print(f'{h.intdigest():016x}')"
# 2d06800538d394c2  -- the first row of tests/unit/hash/hash.expected
```

`lambda/test_chunk_key.py` checks the same agreement against every vector in
that file, and is the test to run after any change here.
