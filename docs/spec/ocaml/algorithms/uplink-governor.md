# The uplink governor — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/uplink-governor.md](../../algorithms/uplink-governor.md).
Not normative. Finding numbers refer to [the 2026-10-01 review](../../review/2026-10-01-rewrite.md).

## Code map

| Spec concept | Code (`lib/store/`) |
|---|---|
| Admission (§4.1), the ticket | `Uplink.acquire`, `try_acquire`, `completed`, `abandoned`, `Uplink.ticket`; `request_overhead` is added inside both |
| One attempt, admitted and reported once | `Uplink.admitted`, called by `Object_store.make` inside `Retry.ladder`, so a retry is admitted again, and by `request` in `http_proxy/http_proxy_client.ml` |
| A store without a link | `Uplink.none` |
| Store → link wiring, probe | `create_store` in `lib/domain/domain.ml`: `Uplink.link`, then `Uplink.attach` with `Domain.probe` (the store's `probe` of the domain cursor where declared, else its `head_opt`) and its `Health.t` |
| Receipt stamp | `Store.stamp`, `Store.t.probe`, declared by `Http_proxy_client` only; the header's shape is `Proxy_wire.receipt_header`, `receipt` and `receipt_of_string`; the server reads `Server.request.received` and `Store_server.handle` stamps the `` `Api `` route; the client reads `Client.response.sent` |
| Budget (§4.2) | `Uplink.Budget` (`create`, `fits`, `admits`, `take`, `spends`, `spend`, `slice`, `release`, `wait_for`, `set_rate`); `burst_seconds`, `stall_timeout`, `window_safety`, `slice_time`, `min_slice` |
| Gate (§4.3) | the lines `first`, `chunks` and `slices`, `next`, `room`, `enter`, `await_turn`, `pump`, `arm`, `left` in `uplink.ml`; the class is the `~chunk` argument of `acquire` and `admitted`; `pace` serves the slices, and `admitted` hands it to the attempt, which passes it to `Tsync_http.Client.request ~pace` |
| Law (§4.4) | `Uplink_law`: `path_name` (`` `Round_trip `` or `` `One_way ``), `tick`, `completed`, `observe_delay`, `timed_out`, `rate`, `phase`, `capacity`, `queueing`, `achieved`, `limit`, `base_delay`; the signal filter is `filter` |
| Report, split, wire shapes (§4.5) | `Uplink_lease`: `report`, `wants`, `split`, `request`, `answer`, `grant`, their JSON codecs, `default_link` for the flat shape |
| Modes | `Uplink.own`, `Uplink.lease`, `Uplink.renewal`; `set_mode`, `renew`; `missed_before_local`, `renewal_timeout`, `local_retry` |
| The step (§4.6) | `step`, `lessee_report`, `probe_round`, `timeouts_since`, `split`, `dormant`, `lease_ttl`; `ticker`, `ensure_ticking`, `step_all` |
| Lessee liveness | `Fs.pid_alive` and `lease_ttl`, in `step` |
| Saved state (§4.7) | `Uplink_law.restore`; `save_state`, `read_saved`, `state_save_interval`; the file is `uplink.json` in the data directory |
| Timeout counter | `Health.timed_out`, `Health.timeouts`, fed by `Retry.ladder` for a LINK failure with `stalled` set |
| Stall detector | `Rt.with_stall_timeout` in `Client.request` (`lib/http/client.ml`) |
| Status (§4.9) | `Uplink.status`, `link_status`, `lessee_status` |
| Who owns | the supervisor (`lib/supervisor/supervisor.ml`), or the service process on macOS (`bin/daemon_cmds.ml`); every command sets `Uplink.lease` over the supervisor's socket (`bin/cli.ml`) |
| Tests | `tests/unit/uplink_test` (budget, gate, wire shapes), `uplink_law_test` (the law against a simulated link), `uplink_one_way_test` (download queues against a control link), `uplink_modes_test`; `tests/store/proxy_stamp_test` (the stamp over the wire) |

## Where the code departs from the spec

- **There is no machine-wide governor lock.** The supervisor, or the macOS service process, is the
  owner. A process that reaches no owner stays Local and tries the lease again every `local_retry`; it
  never becomes owner (§4.5 has it take the lock).
- **Bytes left in the kernel's send buffer are not progress** (finding 23). The stall detector counts
  request-body chunks as they are written; a body fully handed to the kernel on a slow link can still
  stall out.
- **Capacity is estimated with nothing completed** (finding 137). A ramp that ends while `achieved` is
  zero takes `r / √step` unbounded by throughput, so the rate overshoots.
- **Lessee bytes are credited as a tick-long burst** (finding 137): `step` calls `Uplink_law.completed`
  with `elapsed = tick_interval` for what lessees report, whatever each body took.

## Learnings

- The budget, the law and the split never read a clock: they are handed `now`, so tests drive them on
  a fake clock and read each decision at a chosen instant.
- `try_acquire` checks and takes under the gate's mutex, in one step. Fibers run on a pool of domains,
  so a check and a take in two calls admit twice.
- Admission, the renewal and the law's computation run as `` `Direct `` work (`Rt.within` in `renew`);
  probes and the saved state do not.
- Growth only when held back and bytes are moving (`limited && achieved > 0`): without it an idle
  process's rate runs away, and its capacity is read off a rate that never met an edge.
- Completions are spread over their duration: a long body counted at its end reads as a burst and
  inflates the capacity.
- The capacity estimate is bounded by twice the achieved rate, and an edge is confirmed on two ticks: a
  single-body sender otherwise reads a slow link as a fast one.
- A missing sample while bytes are in flight leaves `queueing` unchanged; only an idle link halves it.
- Both stamp clocks are `Rt.now` (`CLOCK_MONOTONIC`, shared by every process of a machine, which A6 asks). `Rt.boottime` is not used: on Windows it is `GetTickCount64`, whose 10–16 ms steps are a third of the target delay.
- A law test that disturbs a link compares it with an undisturbed twin: the periodic ramp builds its own queue every minute, and a before/after reading takes that queue for the disturbance.
- A simulated link needs a bounded buffer (a few hundred ms of capacity) past which the sender is held
  to its share: with an unbounded queue the first doubling builds seconds of delay that no real
  bottleneck holds, and Steady spends a minute draining it.
