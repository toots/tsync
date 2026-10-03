# The http-proxy frontend — OCaml implementation notes

Companion to the spec [../../frontends/http-proxy.md](../../frontends/http-proxy.md). Not
normative. Section numbers in parentheses are the spec's.

Code: `lib/frontends/http_proxy/` (`store_server.ml`, `share_server.ml`, `watch_gates.ml`,
`proxy_options.ml`, `http_proxy_options.ml`). The wire both sides speak is
`Tsync_http_proxy_client.Proxy_wire` (`lib/store/http_proxy/`), the HTTP server `Tsync_http.Server`.

## Where each part lives

| Spec | Code |
|---|---|
| Descriptor, process (§A2) | `Http_proxy_options` registers `http-proxy` with `presenting = None`. `Supervisor.assign` adds one `store-server` child; `Daemon_cmds.store_server` runs `Store_server.run`. |
| Configuration (§A3) | `Proxy_options.resolve` answers a `listener` and a `binding` per domain; `listener_value` (one distinct value across bindings) and `inherited` (the secret) raise `Config.Invalid` naming the option. |
| Routes (§A4.1) | `Store_server.route`, built in `run` from `Domain.build ~owner:false ~poke`, `Domain.store` and, for shares, `Share_server.of_context (Domain.context domain)`. |
| Pipeline (§A4.2) | `Store_server.handle`: `serve_share` and `listener_endpoint` first, then `parse_op`, `fresh`, `read_within`, `verifies`, `admitted`, `execute`. |
| Route selection (§A4.3) | `key_names`, `bulk_names`, `route_for`, `within`, `share_candidates`. |
| Endpoints, read-only (§A4.4, §A4.5) | the `op` variant; `execute`, `writable`. |
| Admission (§A5) | `derive_bound`, `is_data`, `admitted`: an `Rt.Semaphore` of the bound and an `Atomic` count of requests holding or awaiting a slot. |
| Error mapping (§A6) | `store_failure`; `bad_request`, `unauthorized`. `Server` adds `Date` to every response. |
| Watch coalescing (§A7) | `Watch_gates.wait`. |
| Bulk answers (§A8) | `children`; the caps are `Proxy_wire`'s. |
| Share server (§A9) | `Share_server`: `claims`, `handle`, `load`, `stream`, `file_response`, `listing`, `zip_response`, `browse_page`, `parse_range`, `disposition`, `fill`, `script_json`; assets in `Share_assets`. |
| Status (§A10) | `listener_endpoint`, `verified_routes`, `collect`, `presented`, `self_report`; `Status_page.html`. |
| Control socket (§A11) | `control`, served by `Ipc.serve` on `Paths.store_server_socket`. |
| Counters (§A12) | `tally_names`, `count`, `count_bytes`, `listener_report`, giving `Status_report.listener`. |
| Lifecycle (§A13) | `run`: routes, `Ipc.serve`, `Server.serve`, `Stop.wait`, `Server.close`, `Ipc.close`. |

## Where the code departs from the spec

- **The body is read before the data slot is taken.** `handle` reads the body within
  `read_within`'s reservation and verifies the signature, then calls `admitted`, so an unsigned body
  that drips holds memory reserved from its declared length and no slot. §A4.2 and §A5 count the
  body read inside the slot. A body slower than `body_deadline` is answered 408 `body too slow`.
- **Counters.** `Status_report.listener` has `in_flight`, `data_in_flight` (requests holding or
  awaiting a slot, together), the two byte totals and the tallies. It has no `dataWaiting`, no
  `requestsPerSec` and nothing of the share bound (finding 142).
- **Status collection** asks the owner socket of each verified route for
  `Stats ("frontend" :: arg)`, not a list of peer sockets. The `totals` arguments are forwarded and
  the owners ignore them ([07](../07-daemon-cli.md)).
- **Memory.** A bulk answer is encoded whole (`Proxy_wire.encode_bodies`, `encode_folders`) after
  reading eight bodies at a time inside one slot; for a client sending `Proxy_wire.partial_header`
  a get-multi answer stops once it holds `bulk_answer_budget`. A share response holds a share slot
  only and reads each chunk it covers whole (finding 81).

## Learnings

- **One wire module for both sides.** The server spells no header, key encoding or frame itself:
  `verify`, `fresh`, `canonical_query`, `parse_query`, `decode_key`, the listing JSON, the bulk
  frames and the caps (`watch_max`, `bulk_answer_budget`, `bulk_folders_max`) are `Proxy_wire`'s,
  which the client driver uses too.
- **Operations are a closed variant, and two of its functions are not exhaustive.** `tally` and
  `key_names` match every constructor, so a new operation does not compile until it is routed and
  confined. `is_data` and `body_limit` end in a wildcard: a new operation is ungated and takes no
  body until it is listed there.
- **A refusal leaves the pipeline as an exception** (`Answer`), raised by `answer`, `bad_request`,
  `unauthorized` and `writable`, caught once at the end of `handle`. A store failure is a `Fail.E`
  mapped by `store_failure`.
- **Admission's check and its count are one step**: `Atomic.fetch_and_add` on `pending` decides
  the refusal, with a queue of `queue_per_slot` (4) waiters per slot, and the semaphore hands slots
  over first in, first out.
- **Body memory is reserved before a byte is read**, from the declared length, by one
  `fetch_and_add`, and given back in a `finally`.
- **A signature is checked over the canonical query, then over the target as sent** (`verifies`).
- **The watch gate's two critical steps share one mutex** (`Watch_gates`): a waiter's
  increment-and-start, and the loop's check-and-remove. The token is an `Atomic`. A waiter reads
  `Rt.Signal.version` before checking the token and waits `~since` it, so a broadcast in between is
  not lost.
- **A watch loop that ends any other way gives the watch back** (pitfall C-7.10): its `finally`
  clears `watching`, so the next waiter starts another. The loop is spawned before the waiter's own
  first read, which may raise.
- **A stop answers held watches at once**: each waiter registers `Stop.on_request` to broadcast its
  gate, so `Server.close` does not wait out their deadlines.
- **A share slot travels with its response.** `serve_share` takes it with `try_acquire`, answers
  503 before any header when none is free, and releases it in the stream's `finally`, or at once
  for a response that is not a stream or a failure ([README](../README.md) lesson 8).
- **Bytes of a streamed answer are counted as they are written**: `count_bytes` wraps the stream's
  writer.
- **Deferred work goes to the owner.** A domain built with `~owner:false` records the copies its
  writes owe in the owner's logs and calls `~poke`, here `owner_poke`: an `Ipc.advisory` `poll`.
- **The control socket decodes with `Protocol`**, so its replies and failure codes are the owner
  sockets'. `ping` is answered by `Ipc.serve`; `status` is matched before the decode.
- **Assets are compiled in by a dune rule**, not a preprocessor: `share_assets.ml` and
  `status_page.ml` are generated by `cat` into quoted string literals, from `lambda/` and
  `status_page.html`. The mime table is parsed once, when `Share_server` initialises.
- **A share is served from a `Context`**, never a checkout: `Share_server.of_context` takes the
  store and `Tree.Make (C)`'s `find`, `children` and `anchor`. `stream` checks each chunk's length
  and key and fails the response on a mismatch.

## Tests

- `tests/store/proxy_test`: the store contract through a listener, routing and read-only
  refusals, a throttling backend, dripping unsigned bodies against the data slots, watches
  including a stop. Its watch check passes at the client's polling floor (finding 103).
- `tests/store/proxy_wire_test`: signatures, the canonical query, keys, listing JSON, bulk frames.
- `tests/store/share_test`: ranges, `content-disposition`, single-pass templating, JSON in a
  script.
