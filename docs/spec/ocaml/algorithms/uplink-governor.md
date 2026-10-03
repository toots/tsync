# The uplink governor — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/uplink-governor.md](../../algorithms/uplink-governor.md). Source references are at commit `4c32fa96`.

## Code map

| Spec concept | Code |
|---|---|
| Admission record | `Uplink.admission` `{acquire; completed; abandoned; now; waiting; try_admit}` (`lib/backends/uplink/uplink.ml`); caller `Backend.counted`'s `governed` (`lib/backends/api/backend.ml`), around `put`/`put_if_absent`; unwired stores use `ungated` |
| Store → link wiring, probe attach | `Domain.admission_for` (the backend's `link`, default `"wan"`, class `Background`); `Domain.attach_probe` (`head_opt cursor_key`, `held = Health.is_held`, `timeouts = Health.timeouts`; skipped when `local_path` is set) in `lib/domain/config/domain/domain.ml` |
| Best-effort forward | the copy target's `room_for` = the store's admission `try_admit` |
| Budget | `Uplink_budget` (`create`, `admits`, `take`, `release`, `wait_for`, `set_rate`, `window_bytes`); `stall_timeout = 60`, `window_safety = 0.5`, `burst_seconds = 2`; the GCS driver reads `stall_timeout` |
| Gate | `Uplink.Make.gate` / `room` / `acquire` / `pump` / `arm` / `left` / `fail_waiting`; `small_body = 65536` |
| Law | `Uplink_control` (`tick`, `read_delay`, `completed`, `observe_delay`, `timed_out`, `measured_capacity`, `lower_capacity`, `ceiling`, `limit`); ring buffers `Uplink_control.Window`; constants `initial_rate`, `tick_interval`, `probe_timeout`, `gain`, `decrease_floor`, `base_window`, `rate_window`, `probe_up_every`, `backoff_hold` |
| Settings | `Uplink_control.settings` / `default_settings`; config via `Conf_parsing.uplink_of_json`, `link_settings`; `Uplink.configure` (first writer wins) |
| Report, split, lessee table | `Uplink_lease` (`report`, `wants`, `can_use`, `water_fill`, `split`, `live`, `rate_for`, `drain`, `record`, `report_of_json`/`report_to_json`) |
| Modes, ticker, step, renewal | `Uplink.Make`: `process`, `mode`, `own`, `lease_through`, `lease_renewal`, `renew`, `read_answer`, `answer_json`, `fall_to_local`, `maybe_retry`, `ticker`, `ensure_ticking`, `step`, `probe_round`, `own_report`, `timeouts_since`, `dormant`; `retry_every = 30`, `missed_before_local = 3` |
| Lwt instance, shutdown, IPC | `lib/lwt/core/uplink_lwt.ml`: `own_links`, `lease_from ~socket_path` (1 s `Ipc_lwt.send_lwt` timeout), `Shutdown.on_request → cancel_waiting … Stopping`; the daemon's sync-socket `{"action":"uplink"}` handler (`launcher.ml`) calls `lease_renewal`, reading a flat report as `Uplink.default_link` and answering it with a top-level `rate` |
| Timeout counter | `Health.timed_out` / `Health.timeouts`, fed by `Retry.with_retry` |
| Stall detector | `Http_client` `timeout` via `Clock.with_stall_timeout` (wall clock, findings G12) |
| Status | `Uplink.json` / `json_links` |
| Tests | `tests/unit/{uplink_budget,uplink_control,uplink_lease,uplink_modes,uplink,backend_capped}`; the control-law test drives the law against a simulated fluid link on a fake clock |

## Where the current code differs from the spec

- **The decrease floor at a ramp end is dead.** `next = max(rate·0.5, h·C)` is then clipped by `min(next, ceiling = h·C)`, so the rate always lands on `h·C`. The spec applies the floor after the ceiling: no tick cuts more than half.
- **Baseline drift.** A path's base is the plain minimum of 10 × 60 s cells; after ten minutes a queue that stood the whole time becomes the baseline.
- **No samples reads as "no queue"**: a tick without samples halves `queueing` even while bytes are in flight (all stores held, a lessee renewal missed).
- **Retries are not re-admitted**: admission wraps the whole ladder in `Backend.counted`, so re-sent bytes bypass the budget and `elapsed` includes backoff sleeps.
- **No per-request overhead** is billed.
- **Foreground and disabled admissions** release bytes they never took (`acquire` returns without `take`, but `completed`/`abandoned` still `release` and feed `completed`). Latent: nothing uses `Foreground`.
- **Floors oversubscribe**: every party gets at least `min_rate`, so `n` parties can be granted more than the law's rate; a newcomer gets a provisional `max(min_rate, last_total/(1+live))` until the next split.
- **Dead lessees linger** `3·interval + probe_timeout` (16 s): nothing checks the pid.
- **No persistence**: every daemon start re-ramps from 256 KiB/s with ×2 steps.
- **Ownership** is the daemon's (`own` before its engines start); commands and forked children lease over the daemon's sync socket. There is no machine-wide lock, and a Local process never becomes owner.
- **`try_admit` then `acquire`** are separate calls, atomic only under Lwt's cooperative scheduling.
- **Wall clock** in the stall detector (findings G12).
- **Dead code**: `Uplink.capped`, `Uplink.compose` (tests only), class `Foreground`.

## Learnings

- The budget, law and split never read a clock: they are handed `now`, so tests drive them on a fake clock and read each decision at a chosen instant. Keep that shape in any port.
- Growth only when *held back* (commit 80b5e045): without it an idle daemon's rate ran away to terabytes a second and its capacity was read off a rate that never met an edge.
- Completions spread over their duration (859ecf1f): a long body counted at its end read as a burst and inflated the capacity.
- The capacity estimate bounded by 2× achieved and two ticks to end a ramp (80b5e045): a single-body sender read a few MB/s link as twenty, and one probe behind one body read as a phantom queue.
- Small-body overtaking bounded by the head's size, and the lessee aging period including the probe timeout (c3c4a983).
- Links separate (a8c127c7) and one renewal for every link (1ea95d84); timeouts counted per member (4f0bc2ca).
- Gates wake waiters with `Io.wakeup_later`, so a woken waiter does not run inside `pump` while the line is iterated.
- Ownership belongs to the supervisor alone: tsync is expected to run under it, so there is no machine-wide governor lock, and a process that reaches no owner stays Local and retries the lease every LOCAL_RETRY.
- A simulated link needs a bounded buffer (a few hundred ms of capacity) past which the sender is held to its share: with an unbounded queue the first ×2 ramp step builds seconds of delay that no real bottleneck holds, and Steady spends a minute draining it.
