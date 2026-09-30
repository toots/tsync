# The http-proxy frontend — OCaml implementation notes

Companion to the language-neutral spec [../../frontends/http-proxy.md](../../frontends/http-proxy.md). See [README.md](../README.md) for how these notes are organised. Security gaps of this code against the spec: [../algorithms/security-model.md](../algorithms/security-model.md).

Each note names the spec section it implements.

## B-I. Runtime-independent OCaml learnings (valid under Lwt or OCaml 5 direct style)

**B1. Registration (A2).** `frontend_http_proxy.ml` is a one-line link-time side effect calling `Http_proxy_frontend.register`, which registers `Frontend.S` with `serving = Daemon { topology = `One_process; listens = Some `Proxy_socket; start }`, `tree = `Replicated`, `availability = Checkout.availability`, and the `Field_spec` list as the option spec. Linking the library in or out is what makes the frontend exist in a build.

**B2. One wire module for both sides (A4, A7).** `Tsync_backend_api.Http_proxy` (`lib/backends/api/http_proxy.ml{,i}`) holds `Auth` (header names, `request_headers`, `verify`, `max_skew = 300.`), `Watch` (`max_seconds = 30.`, parameter and header names) and `Wire` (key base64url, listing JSON, body/folder framing including the piecewise `body_parts`/`folder_parts` used for streaming). The server never spells a header or a frame itself; keep it that way so client and server cannot drift. `Auth.verify` hashes the body straight from the `Bigstring` (Digestif) and compares with `Eqaf.equal`.

**B3. Ops as a closed variant (A4.4).** `type op = Get | Head | Put | Put_if_absent | Delete | Watch {…} | Get_range {…} | Get_multi | Children_multi | Delete_multi | Copy | List_all | Share_url | Chunk_size | Max_concurrency | Verified | Bad | Unknown`. Four total functions over it carry the policy: `op_keys` (confinement), `route_key` (first of `op_keys`), `data_kind` (admission: `Get` / `Put` / `Meta`), `op_name` (tally). Adding an op without updating all four is a compile warning (non-exhaustive match), which is the point of the variant; `op_keys` in particular is the security check, not an optimisation.

**B4. Route record carries closures, not modules (A4.1, A10).** Each `route` holds the composite store as a first-class `(module Backend_lwt.Store)`, the share server as a record of two closures (`serves`, `handle`) built from `Share_server.Make (C)`, and `diagnose` as a closure over `Diagnostics.Make (C)`. This erases the per-domain functor instantiation so heterogeneous domains sit in one list. `make_route` is where the per-domain `Conf_lwt.S` is unpacked (`val b.Frontend.conf`).

**B5. Listener-scoped options (A3).** `listener_value` = at most one distinct non-empty value across bindings, else `failwith`; `inherited` = own value, else the unique common value. Both treat `""` as unset (`nonempty`). All `failwith`s run before `Domain_engine.run`, so a config error kills the child before any loop or socket exists.

**B6. cohttp specifics (A4.2, A8).**
- `Cohttp_lwt.Body.to_bigstring` reads the whole body up front (spec A17.1).
- Single objects: `Body.of_bigstring (`Passthrough data)` — no copy; safe only because the buffer was fetched for this response alone.
- Bulk answers: `Lwt_stream.map_list parts (Lwt_stream.of_list items)` then `Body.of_stream`; byte counters bumped inside the stream map, i.e. as pieces are produced, not when the handler returns.
- TLS: `Cohttp_lwt_unix.Server.create ~mode:(`TLS (`Crt_file_path, `Key_file_path, `No_password, `Port))`; `~stop` ends the accept loop.
- `Cohttp_lwt_unix.Server.respond_string` for small bodies; HEAD answers use it with an empty body plus headers.

**B7. Error classification (A6).** `Backend.classify exn = Retry.Permanent` → `` `Conflict `` + `Log.info`, else `` `Internal_server_error `` + `Log.err`; the body is `Retry.reason exn`. The same classifier drives the client's retry ladder, so server and client agree on "permanent" by construction.

**B8. Share server functor (A9).** `Share_server.Make (C)` instantiates `Logical_key.Make (C)`, `Remote_lwt.Make_with_layout (C) (Layout_lwt.Identity)` (identity layout: the logical key's spelling is the backend key), `Data_lwt.Make (C) (R)` for chunk-cache `pread`, and `Inode_tree_lwt.Make (C)` for folder namespaces (`children`, `find`, `namespace_prefix`). File-key confinement is `Lk.rel_of_string`, which returns `None` for any key outside `C.domain_prefix`. Failures inside the handler are `exception Error of status * string`, raised by `fail` and caught once at the top of `handle`; anything else becomes 500.

**B9. Embedded assets (A9.6, A10).** `ppx_blob` embeds `lambda/{browse.html,player.js,mime.json}` and `stats.html`; the dune stanza lists them in `preprocessor_deps`. The mime table is parsed at module init and `failwith`s on malformed JSON, i.e. at program start.

**B10. Status collection (A10, A11).** `status_json` = `Lwt_list.map_p route.diagnose` over routes plus `Lwt_list.map_p Status_report.ask ~arg:Status_report.frontend_only` over `routes × peers`, merged by `Status_report.of_answers ~local:(self_json …)`. `/stats` and `/api/v1/stats` render the same value through `Status_report.text` / `Yojson.Safe.to_string`. The control-socket error replies go through `Ipc_handler.error_reply` so codes match the domain sockets.

**B11. Test seams.** `bounded`, `gate`, `make_gate`, `fits`, `parse_op`, `route_for`, `within`, `op_keys`, `data_kind`, `route_key`, `share_server_for`, `serve_domains`, `ipc_handler`, `make_route` are exported for `tests/frontends/{http_proxy,proxy_bound,proxy_watch}`; the tests drive them directly, without an HTTP listener.

## B-II. Lwt / functor-specific learnings, and what they become under effects/domains

**B12. Admission pools (A5).** `Io_lwt.Bounded` instances held in `option ref` globals, set once by `set_limits`:
- `gate` — `~max:n ~max_waiting:(16*n)`; `bounded` calls `use_or g ~busy run` for `` `Get | `Put ``; `use_or` releases in `Io.finalize`, so a failing or cancelled request returns its slot (pinned by proxy_bound's "same budget afterwards").
- `batch_reads` — `~max:n`, no waiter limit; passed as `?slots` to `Backend_lwt.Batched(B).get_many`.
- `Share_server.read_slots` — module-level, `~max:16`, no waiter limit, taken with `use` **before** `Bigarray.Array1.create`.
Under OCaml 5 these become a semaphore plus a bounded waiter count; `use_or`'s "refuse when the queue is full" needs the count check and enqueue to be one atomic step.

**B13. Watch gates (A7).** `gates : (string, gate) Hashtbl.t` with `gate = { mutable token; mutable waiters; mutable watching; woken : unit Lwt_condition.t }`. The loop is `Lwt.async`ed by `start_watching`. Two atomicity assumptions hold only because Lwt does not preempt between binds:
- in `exec (Watch …)`: `gate.waiters <- gate.waiters + 1; start_watching …` — no bind between;
- in `watch_loop`: `if gate.waiters = 0 then (Hashtbl.remove …; gate.watching <- false; …)` — no bind between.
The waiter itself uses `Lwt.pick [Lwt_condition.wait gate.woken; Lwt_unix.sleep left]` then re-checks (spurious wakes are fine) and decrements in `Lwt.finalize`. Under effects/domains: one mutex per gate table (or per gate plus table), held across increment-and-spawn and across check-and-remove; `Lwt_condition` becomes a `Condition` or an Eio `Condition`/promise broadcast; `Lwt.pick` becomes a timeout-bounded wait that must cancel cleanly. Note that `gate.token` is written by both paths unguarded; with domains it must be an `Atomic.t` or under the gate lock.

**B14. Counters (A12).** `counters : (string, int) Hashtbl.t`, `in_flight : int ref`, and `Metrics` counters are touched only on the event-loop thread. With domains they need `Atomic` or a per-domain shard summed on read.

**B15. Share streams (A9.4, A9.7).** `Lwt_stream.from` pulls one block per call; the ZIP state (`queue`, `cur`, `done_`, `Zip_stream.t`) lives in refs captured by the closure, touched only on pull, which cohttp serialises. `logged` wraps each pull so a failure after headers is logged before re-raising (cohttp logs nothing of ours). Under direct style this is a plain loop writing to the response sink; the slot-before-buffer order must be kept.

**B16. Manifest memo (A9.4).** `Hashtbl` cleared by `Hashtbl.reset` at 256 entries, inside `Make (C)`, so one memo per share-enabled domain. Lookups and inserts are separated by a bind (the fetch), so two concurrent misses both fetch — harmless duplication, not a race on the table under Lwt; under domains it needs a lock or a concurrent map.

**B17. Lifecycle (A13).** `start` runs `Domain_engine.run (fun ~ready -> …)`: stop is an `Lwt.wait` pair resolved by `request_stop` (guarded by `Lwt.state stop = Sleep`, a check-then-act that is safe only without preemption) after `Shutdown.request ()`; signals via `Lwt_unix.on_signal`. The control socket is `Lwt.async (Ipc_lwt.serve ~until:drained …)`, and `drained` is woken after `Domain_engine.drain_for_stop`, which is what closes and unlinks the socket once. `Lwt.async_exception_hook` is set to a logger so the watch loops and share streams never take the process down; an exception escaping `Lwt_main.run` itself is fatal by the engine's design.

**B18. Capability derivation (A5).** `Lwt_list.map_s` over routes with `Lwt.catch … (fun _ -> Backend.no_caps)`, then `Backend.merge_caps`; sequential on purpose (few routes, startup only). Swapping to a parallel map is harmless but gains nothing.

## B-III. History and gaps at the spec snapshot

**B19. Commits behind the rationale (A16).** 409 for permanent failures: 48e797b4. One watch per key, read on arrival: cf3684d8. Gate data not metadata, 16× queue, batch pool: 4060b0b1 (a gate of 4 was serving 128 reads through the batch layer's default width). Bulk answers from listed sizes, streamed: 34183bb1 (a 90 MB folder answered whole through a growing buffer plus a final copy killed a 400 MB host). One "who serves shares" predicate: ca6ed151.

**B20. Process shape.** The launcher forks one child for the whole `http-proxy` group; it inherits the stores built before the fork (stopped, `resume = true`), leases uplink bandwidth from the parent and routes "replica job recorded" to the parent as a `rescan`. The spec requires the listener to run in the domains' owner.

**B21. Where the code falls short of the frontend spec.**
- The gate table is keyed by key string, not (route, key), and any key may be watched; the whole body is the token, so a watch on a chunk key reads and holds the chunk.
- `wait` is parsed with `float_of_string`: `nan` passes the clamp (min with NaN is NaN) and leaves the deadline undefined; a negative `wait` answers 204 at once.
- An unparseable `max_keys` lists everything; `if_absent` with an unknown value is a plain PUT.
- Claims, deletes, copies and delete-multi bypass the gate; there is no connection cap, so nothing bounds them.
- Stop ends the accept loop and drains without awaiting in-flight requests.
- The control socket answers a JSON non-object with `internal`.
- The default port without TLS is 80 on all interfaces; there is no `bind` option.
- `/s/` accepts any method.
- Share bytes are read through the domain's chunk-cache data path (`Data_lwt.pread`, fetch-on-miss into the cache); the spec (R-2) has the store server own no domain state and stream shares from the stores.
- Deferred replica jobs recorded by the child are signalled to the parent as a `rescan`, not submitted to an owner inbox.
- No server-side GC gate: a proxied `Put` of a manifest is a plain `B.put`, no promotion, no missing-chunk check; chunk reads do not fall back to `chunks.from/`.
- No `Date`, `x-tsync-kind` or `x-tsync-etag` headers.

## B-IV. Resource strategy (not normative)

The spec leaves these to the implementation (P6). Values at the snapshot:
- Admission gate `max:n`, waiter queue `16 × n`; batch-reads pool of `n`, no waiter limit (separate from the gate so a request holding a gate slot never waits on the same pool: deadlock).
- Share reads in 256 KiB blocks, each taking one of 16 process-wide read slots **before** allocating its buffer (this order is what bounds memory); no waiter limit, because headers are already sent. File manifests memoised per key, cleared at 256 entries.
- Single-object answers handed to cohttp without a copy; bulk answers streamed as frame pieces, bodies held once in the store's buffers; byte counters bumped per piece.
- ZIP: one block in memory at a time; the member list is computed before the response starts.
