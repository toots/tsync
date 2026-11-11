"""Site shares through the share function (http-proxy §A9.9, security §6.5,
object-store-common §6), against moto:

    pytest lambda/test_site.py
"""

import base64
import importlib
import os
from urllib.parse import urlparse, unquote

import boto3
import pytest
from moto import mock_aws

from test_handler import (
    BUCKET,
    PREFIX,
    dir_share,
    event,
    put,
    put_file,
    put_folder,
    share_manifest,
)

SITES = "tsync-sites"
SITES_DOMAIN = "sites.example.org"
SHARE_HOST = "share.example.org"
TOKEN = "a" * 32


def load_handler(sites=True):
    os.environ.update(
        BUCKET=BUCKET, SHARES_PREFIX=PREFIX, PRESIGN_TTL="600",
        MAX_BYTES=str(10), AWS_REGION="us-east-1",
    )
    for k in ("SITES_BUCKET", "SITES_DOMAIN"):
        os.environ.pop(k, None)
    if sites:
        os.environ.update(SITES_BUCKET=SITES, SITES_DOMAIN=SITES_DOMAIN)
    import handler

    return importlib.reload(handler)


@pytest.fixture(autouse=True)
def sites_env():
    yield
    for k in ("SITES_BUCKET", "SITES_DOMAIN"):
        os.environ.pop(k, None)


@pytest.fixture
def s3():
    with mock_aws():
        c = boto3.client("s3", region_name="us-east-1")
        c.create_bucket(Bucket=BUCKET)
        c.create_bucket(Bucket=SITES)
        yield c


INDEX = b"<html><body>souvenirs</body></html>"


def site_folder(s3):
    """root/site: index.html, app.js, style.css, a sub folder with a picture,
    and a symlink, which is never published."""
    put_folder(s3, "root", "site", "site")
    put_file(s3, "site", "index.html", [("aaaa-0001", INDEX)])
    put_file(s3, "site", "app.js", [("aaaa-0002", b"go()")])
    put_file(s3, "site", "style.css", [("aaaa-0003", b"body{}")])
    put_folder(s3, "site", "img", "img")
    put_file(s3, "img", "a.gif", [("aaaa-0004", b"GIF89a")])
    put_file(s3, "img", "index.htm", [("aaaa-0005", b"<p>pictures</p>")])
    put_file(s3, "site", "link.html", [], symlink="index.html")


def site_share(s3, token=TOKEN, **extra):
    return share_manifest(s3, token, dict({
        "v": 1, "domain": "d", "type": "dir", "folderId": "site",
        "filename": "site.zip", "expires": 9_999_999_999, "site": True,
    }, **extra))


def on(host, path, headers=None):
    e = event("x")
    e["rawPath"] = path
    e["headers"] = dict(headers or {}, host=host)
    return e


def published(s3, token=TOKEN):
    r = s3.list_objects_v2(Bucket=SITES, Prefix=token + "/")
    return sorted(o["Key"][len(token) + 1:] for o in r.get("Contents", []))


def head(s3, key):
    return s3.head_object(Bucket=SITES, Key=TOKEN + "/" + key)


def test_first_visit_publishes_then_redirects(s3):
    h = load_handler()
    site_folder(s3)
    site_share(s3)
    r = h.handler(on(SHARE_HOST, "/" + TOKEN), None)
    assert r["statusCode"] == 302, r
    assert r["headers"]["Location"] == "https://%s/%s/" % (SITES_DOMAIN, TOKEN)
    assert r["headers"]["Cache-Control"] == "no-store"
    assert published(s3) == ["app.js", "img/a.gif", "img/index.htm", "index.html", "style.css"]
    assert s3.get_object(Bucket=SITES, Key=TOKEN + "/index.html")["Body"].read() == INDEX
    assert head(s3, "app.js")["ContentType"] == "text/javascript; charset=utf-8"
    assert head(s3, "style.css")["ContentType"] == "text/css; charset=utf-8"
    assert head(s3, "index.html")["CacheControl"] == "no-cache"
    # The share ceiling (10 bytes here) does not bound a publication.
    assert head(s3, "index.html")["ContentLength"] > 10
    s3.head_object(Bucket=BUCKET, Key=PREFIX + "cache/" + TOKEN + ".site")


def test_link_preview_fetcher_gets_the_card_page(s3):
    h = load_handler()
    site_folder(s3)
    site_share(s3)
    r = h.handler(on(SHARE_HOST, "/" + TOKEN, {"user-agent": "WhatsApp/2.24"}), None)
    assert r["statusCode"] == 200
    assert r["headers"]["Content-Type"].startswith("text/html")
    assert published(s3) == []


def test_without_a_sites_bucket_a_site_is_a_folder(s3):
    h = load_handler(sites=False)
    site_folder(s3)
    site_share(s3)
    r = h.handler(on(SHARE_HOST, "/" + TOKEN), None)
    assert r["statusCode"] == 200
    assert r["headers"]["Content-Type"].startswith("text/html")


def test_sites_domain_serves_pages_and_redirects_files(s3):
    h = load_handler()
    site_folder(s3)
    site_share(s3)
    page = h.handler(on(SITES_DOMAIN, "/%s/" % TOKEN), None)
    assert page["statusCode"] == 200, page
    assert base64.b64decode(page["body"]) == INDEX
    assert page["headers"]["Content-Type"].startswith("text/html")
    assert page["headers"]["Cache-Control"] == "no-cache"
    sub = h.handler(on(SITES_DOMAIN, "/%s/img/" % TOKEN), None)
    assert base64.b64decode(sub["body"]) == b"<p>pictures</p>"
    folder = h.handler(on(SITES_DOMAIN, "/%s/img" % TOKEN), None)
    assert folder["statusCode"] == 301
    assert folder["headers"]["Location"] == "/%s/img/" % TOKEN
    bare = h.handler(on(SITES_DOMAIN, "/" + TOKEN), None)
    assert bare["headers"]["Location"] == "/%s/" % TOKEN
    # Only a token is echoed: `/\evil.com/` reads as `//evil.com/` to a browser.
    assert h.handler(on(SITES_DOMAIN, "/\\evil.com"), None)["statusCode"] == 404
    gif = h.handler(on(SITES_DOMAIN, "/%s/img/a.gif" % TOKEN), None)
    assert gif["statusCode"] == 302
    url = urlparse(gif["headers"]["Location"])
    assert url.netloc == "%s.s3.us-east-1.amazonaws.com" % SITES
    assert unquote(url.path) == "/%s/img/a.gif" % TOKEN
    assert h.handler(on(SITES_DOMAIN, "/%s/nope.html" % TOKEN), None)["statusCode"] == 404
    assert h.handler(on(SITES_DOMAIN, "/%s/%%2E%%2E/x" % TOKEN), None)["statusCode"] == 400


def test_sites_domain_answers_no_share_route(s3):
    h = load_handler()
    site_folder(s3)
    site_share(s3)
    dir_share(s3, "b" * 32, "site")
    assert h.handler(on(SITES_DOMAIN, "/%s/" % ("b" * 32)), None)["statusCode"] == 404
    assert h.handler(on(SITES_DOMAIN, "/%s/list" % TOKEN), None)["statusCode"] == 404
    assert h.handler(on(SITES_DOMAIN, "/"), None)["statusCode"] == 404


def test_a_page_over_the_cap_is_redirected(s3):
    h = load_handler()
    h.SITE_PAGE_MAX_BYTES = 4
    site_folder(s3)
    site_share(s3)
    r = h.handler(on(SITES_DOMAIN, "/%s/index.html" % TOKEN), None)
    assert r["statusCode"] == 302


def test_a_resumed_publication_keeps_matching_files_and_drops_stale_ones(s3):
    h = load_handler()
    site_folder(s3)
    site_share(s3)
    h.handler(on(SHARE_HOST, "/" + TOKEN), None)
    meta = head(s3, "index.html")["Metadata"]
    # Same size and recorded time: kept as is, which is how a cut-short
    # publication resumes.
    s3.put_object(Bucket=SITES, Key=TOKEN + "/index.html", Body=b"x" * len(INDEX), Metadata=meta)
    # Same size at another time: rewritten.
    s3.put_object(Bucket=SITES, Key=TOKEN + "/app.js", Body=b"xxxx")
    s3.put_object(Bucket=SITES, Key=TOKEN + "/old.html", Body=b"stale")
    s3.delete_object(Bucket=BUCKET, Key=PREFIX + "cache/" + TOKEN + ".site")
    h.handler(on(SHARE_HOST, "/" + TOKEN), None)
    body = lambda k: s3.get_object(Bucket=SITES, Key=TOKEN + "/" + k)["Body"].read()
    assert body("index.html") == b"x" * len(INDEX)
    assert body("app.js") == b"go()"
    assert "old.html" not in published(s3)


def test_a_missing_copy_is_published_again(s3):
    h = load_handler()
    site_folder(s3)
    site_share(s3)
    h.handler(on(SHARE_HOST, "/" + TOKEN), None)
    h.remove_site(TOKEN)
    h.handler(on(SHARE_HOST, "/" + TOKEN), None)
    assert "index.html" in published(s3)


def test_a_gone_share_has_its_site_removed(s3):
    h = load_handler()
    site_folder(s3)
    site_share(s3)
    h.handler(on(SHARE_HOST, "/" + TOKEN), None)
    s3.delete_object(Bucket=BUCKET, Key=PREFIX + TOKEN)
    assert h.handler(on(SHARE_HOST, "/" + TOKEN), None)["statusCode"] == 404
    assert published(s3) == []
    # A token never published costs one HEAD, and a copy without its record
    # is the sweep's.
    s3.put_object(Bucket=SITES, Key=TOKEN + "/index.html", Body=INDEX)
    assert h.handler(on(SHARE_HOST, "/" + TOKEN), None)["statusCode"] == 404
    assert published(s3) == ["index.html"]
    site_share(s3, expires=1)
    put(s3, PREFIX + "cache/" + TOKEN + ".site", b"")
    assert h.handler(on(SITES_DOMAIN, "/%s/" % TOKEN), None)["statusCode"] == 410
    assert published(s3) == []
    assert not h.object_exists(PREFIX + "cache/" + TOKEN + ".site")


def test_the_sweep_removes_gone_sites_and_keeps_unreadable_ones(s3):
    h = load_handler()
    live, gone, corrupt = "1" * 32, "2" * 32, "3" * 32
    site_folder(s3)
    site_share(s3, live)
    put(s3, PREFIX + corrupt, b'{"v": 1, "site": "yes", "type": "dir", "expires": 9999999999}')
    for t in (live, gone, corrupt):
        s3.put_object(Bucket=SITES, Key=t + "/index.html", Body=INDEX)
    assert h.handler({"sweep": True}, None) == {"removed": 1}
    assert published(s3, live) and published(s3, corrupt)
    assert published(s3, gone) == []


def test_site_manifests_a_reader_refuses(s3):
    h = load_handler()
    site_folder(s3)
    site_share(s3, site="index.html")
    assert h.handler(on(SHARE_HOST, "/" + TOKEN), None)["statusCode"] == 502
    share_manifest(s3, "c" * 32, {
        "v": 1, "domain": "d", "type": "file", "key": "p/d/manifests/site/x",
        "filename": "x", "expires": 9_999_999_999, "site": True,
    })
    assert h.handler(on(SHARE_HOST, "/" + "c" * 32), None)["statusCode"] == 502


def test_a_missing_chunk_fails_the_publication(s3):
    h = load_handler()
    site_folder(s3)
    put_file(s3, "site", "broken.html", [("dead-0009", b"never stored")])
    s3.delete_object(Bucket=BUCKET, Key=next(
        o["Key"] for o in s3.list_objects_v2(Bucket=BUCKET, Prefix="p/d/chunks/")["Contents"]
        if o["Key"].endswith("dead000000000000-0009000000000000")
    ))
    site_share(s3)
    r = h.handler(on(SHARE_HOST, "/" + TOKEN), None)
    assert r["statusCode"] == 502
    assert r["body"] == "site not published\n"
    assert not h.object_exists(PREFIX + "cache/" + TOKEN + ".site")


def test_a_share_that_cannot_be_read_at_the_end_keeps_its_copy(s3, monkeypatch):
    h = load_handler()
    site_folder(s3)
    site_share(s3)
    monkeypatch.setattr(h, "share_state", lambda token: "unknown")
    r = h.handler(on(SHARE_HOST, "/" + TOKEN), None)
    assert r["statusCode"] == 502
    assert "index.html" in published(s3)
    assert not h.object_exists(PREFIX + "cache/" + TOKEN + ".site")
