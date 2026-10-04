# Run tsync as a server


Rather than give every machine your bucket credentials, or mount the same NAS everywhere, run tsync on one machine and let the others go through it. The **`http-proxy` frontend** serves a domain over HTTPS; the **`http-proxy` backend** uses it. Clients hold one shared secret and no storage credentials.

## The server

Add an `http-proxy` frontend to the domain on the machine that has the disk or the bucket keys:

```json
{
  "domains": [
    {
      "name": "media",
      "versioning": true,
      "symlinks": "keep",
      "frontends": [
        { "type": "http-proxy",
          "port": 8443,
          "secret": "<at least 32 characters>",
          "ssl_certificate": "/etc/letsencrypt/live/nas.example/fullchain.pem",
          "ssl_certificate_key": "/etc/letsencrypt/live/nas.example/privkey.pem" }
      ],
      "backends": [
        { "type": "local", "name": "disk", "role": "main", "path": "/mnt/pool" }
      ]
    }
  ]
}
```

- **The secret** is at least 32 characters. `openssl rand -hex 32` makes one.
- **The certificate.** Set both `ssl_*` options or neither. With both, the server listens on every address, on port 443 unless you say otherwise. With neither it speaks plain HTTP on port 80 and listens **on localhost only**, which is what a reverse proxy on the same machine needs.
- **Mounting it too.** Frontends are per domain, so `"frontends": ["fuse", { "type": "http-proxy", … }]` both mounts the domain on the server and serves it.
- **Several domains.** One server process serves every domain that has an `http-proxy` frontend, on one port. Port, addresses and certificate may be set on one domain only, or identically on each. A domain with no `secret` of its own uses the one the others agree on. `shares` and `readOnly` are always per domain.

Two options per domain:

- `"shares": true` makes the server answer public share links itself ([share links](sharing.md#share-links)).
- `"readOnly": true` refuses writes from clients, while the server's own mount still writes.

## Behind a reverse proxy

If you already run nginx, Caddy or Traefik, let it hold the certificate. Leave out the `ssl_*` options, pick a port, and proxy to it:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    client_max_body_size 300m;
    proxy_request_buffering off;
    proxy_read_timeout 300s;
}
```

`client_max_body_size` is the setting that bites: nginx defaults to 1 MB, and tsync uploads whole chunks, 8 MiB each by default and up to 256 MiB for one request. Uploads fail until it is raised.

If the proxy runs on another machine, the server must listen beyond localhost. That is plain HTTP on your network, so it has to be asked for by name: `"bind": "0.0.0.0"`, or a specific address.

## The clients

```json
{
  "domains": [
    {
      "name": "media",
      "versioning": true,
      "symlinks": "keep",
      "frontends": ["fuse"],
      "backends": [
        { "type": "http-proxy", "name": "nas", "role": "main",
          "url": "https://nas.example:8443", "secret": "<the same secret>" }
      ]
    }
  ]
}
```

- The domain's `name` must be the one on the server.
- `url` must be `https://`. Plain `http://` is accepted only for localhost.
- For a certificate signed by your own authority, add `"ca_certificate": "/path/to/ca.pem"`.
- The client uses the server's chunk size, so that setting lives in one place.
- The clocks of client and server must agree within five minutes: requests are signed with the time.

## Check on a server

On the server itself, `tsync status` and `tsync logs` work as on any machine.

From elsewhere, the server reports over HTTPS to whoever holds the secret:

| Address | Returns |
|---|---|
| `/` | A page that asks for the secret, then shows the report and refreshes it |
| `/stats` | The report as text, as `tsync status` prints it |
| `/api/v1/stats` | The same as JSON |
| `/domains` | The domains this secret opens, as JSON |

The page keeps the secret in the browser's memory and sends only signatures. It works over HTTPS or on `localhost`; a browser offers no signing elsewhere, and the page says so.

A secret shows only the domains it opens. For a script, sign the request the way a client does:

```bash
secret='<the secret>'
path=/api/v1/stats
ts=$(date +%s)
empty=$(printf '' | openssl dgst -sha256 -r | cut -d' ' -f1)
sig=$(printf 'GET\n%s\n%s\n%s' "$path" "$ts" "$empty" \
      | openssl dgst -sha256 -hmac "$secret" -r | cut -d' ' -f1)
curl -sS "https://nas.example:8443$path" \
  -H "x-tsync-timestamp: $ts" -H "x-tsync-signature: $sig"
```

Add `?totals=1` for an estimate of how many objects and bytes each store holds, or `?totals=exact` for a full count. A count lists the whole store, so it is never done unasked. The query string is part of `path` when signing.
