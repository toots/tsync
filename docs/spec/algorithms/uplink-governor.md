# The uplink governor

A delay-driven rate controller for background uploads over a shared network link, with a token-bucket admitter per process and a lease protocol that splits one controller's rate among several processes on one machine.

Concrete names appear only in §10. Everywhere else, "the store" means any remote object store reached over a network path, "a body" means one upload request's payload, and "the link" means a named network path that several stores may share.

---

## 1. Problem and goals

tsync uploads file content in the background, as chunk bodies of up to several MiB plus small metadata bodies. The upload link is usually a consumer uplink with a deep buffer in the modem or router, and the user is on the same link. A sender limited only by TCP fills that buffer. Every interactive flow on the link (a video call, SSH, page loads, DNS) then waits behind seconds of queued upload. This is bufferbloat, and the sender causes it even though it has nothing urgent to send.

Seen as a control problem: **choose a send rate `r(t)` per link so that the link is used near its free capacity while the standing queue at the bottleneck stays near zero.** The only observation available is the round-trip delay of small requests.

Goals:

- **G1 Low standing queue.** In steady state, the queueing delay that tsync adds at the bottleneck stays below a small target (default 50 ms). Transients above it are bounded in size and length.
- **G2 Use the link.** When nobody else wants the link, the rate approaches a fixed fraction (`headroom`, 0.8) of what the link was measured to carry. The rate discovers a link that got faster.
- **G3 Yield.** When other traffic takes a share, tsync's rate falls to what is left, down to a configured floor. When that traffic leaves, the rate recovers within about one probe period.
- **G4 No wind-up.** A sender with little to send must not accumulate permission it has never used, because the first real load would then meet a rate that has never met an edge.
- **G5 Deliverability.** An admitted body must be able to finish before the transport's stall detector gives up on it. A body far back in a deep in-flight backlog would time out while waiting its turn on the wire.
- **G6 One controller per link per machine.** Several processes on one machine (the daemon, forked frontends, one-shot commands) share one link. They must not run independent controllers against it, and a process started beside the daemon must not start cold.
- **G7 Small bodies are not starved.** Cursor and journal writes, which are a few KiB and latency-sensitive, may pass a queued multi-MiB chunk, but only by a bounded amount.
- **G8 Stop quickly.** At shutdown, bodies waiting for admission give up at once and are left owed on disk.

Non-goals:

- **Downloads are never gated.** A read has a user waiting on it.
- **No fairness guarantee between machines.** Each machine runs its own controller, and fairness between them is only emergent (§5.6).
- **No guarantee under a lying clock or probe.** The probe's server-side time is assumed roughly constant.
- **Not a transport congestion controller.** Loss recovery and TCP's own window stay with the kernel. The governor limits only the arrival rate of bodies into TCP.
- **No per-store rate caps.** The mechanism exists, but a per-store ceiling is expressed as "give the store its own link and cap that link" (§9).

---

## 2. System model and assumptions

- **A1 One bottleneck per link.** All stores that name the same link share one bottleneck queue, usually the user's uplink. Different links are independent paths, and a store sits on exactly one link. Stores on one link may be at different network distances, so each has its own base round-trip time.
- **A2 Bodies are opaque and sent whole.** An upload is one request. The server answers only after the whole body has arrived. The transport's timeout is a **stall detector**: it fires after a fixed time (default 60 s) with no byte of the *answer*, and progress on the request side does not reset it. A body queued behind others therefore spends its whole wait inside its own timeout.
- **A3 Completion is observable.** For each admitted body the sender learns once whether it was answered (and after how long) or abandoned. Retries inside one request are invisible to the governor.
- **A4 Delay is observable only by probing.** There is no access to TCP internals. The signal is the round-trip time of a small, cheap, idempotent request to each store: a metadata read of a key every store holds. It carries the bottleneck's queue on the request path, plus base propagation, plus server time. Probes are billed requests, so they are sent only while bytes are in flight.
- **A5 Foreign traffic is invisible except through delay.** Other devices and other applications are never measured directly.
- **A6 Monotonic clock.** Each process has a monotonic clock. Rates are read over windows of seconds, so a wall-clock step of that size would corrupt them. There is no shared clock between processes.
- **A7 Local IPC.** Processes on one machine can reach the daemon's local socket with a short request/response. The daemon may be absent, restarting, or of an older build that refuses the request.
- **A8 Cooperative single-threaded scheduling within a process.** A check and the take that follows it run with no other task in between, unless the caller yields. The admission step's atomicity depends on this (§5.1).
- **A9 Timeouts are counted per store.** Each store keeps a monotonically increasing count of its requests that hit the stall detector. Counting timeouts is separate from marking the store's health.
- **A10 Crashes are free.** No governor state is durable. A crash loses only rate knowledge, never data: an upload that never ran is still owed by whatever queued it.

---

## 3. State

Everything is volatile and per process. Nothing is persisted.

**Per process:**

- `mode ∈ {Owner, Leased, Local}`, the same for all links.
- `daemon`: an optional channel to the owner.
- `missed`: renewals left unanswered in a row.
- `retry_at`: when a Local process with a daemon channel asks again.
- `interval`: the renewal period dictated by the owner.
- `ticking`: whether the single ticker loop runs.
- `defaults` and `overrides[name]`: settings, fixed at the first configuration.
- `links`: a map from name to link, with each link created on first mention.

**Per link:**

| Part | State | Lives in |
|---|---|---|
| **Law** (controller) | `rate`; `phase ∈ {Ramping, Steady, BackingOff}`; `since` (phase entry time); `settled`; `over_target` count; `never_saturated`; `capacity` (optional); `queueing` (EWMA); `samples` pending since the last tick, as (path, delay) pairs; `base[path]`, a sliding minimum over 10 × 60 s cells; `completed`, a sliding sum over 10 × 1 s cells; `drops` | Owner and Local processes. A lessee keeps one too, but its rate is unused while it holds a lease. |
| **Budget** (this process's admission) | `share_rate`; `tokens`; `filled_at`; `in_flight_bytes` | Every process |
| **Gate** (line) | FIFO of (bytes, waker); `armed` (one timer at most); `overtaken` (bytes that passed the current head); `held_back` flag (read-and-clear) | Every process |
| **Probes** | a list of {path name, is_held, timeout counter, probe action}; `last_timeouts` (sum at the last read); `completed_since` (own answered bytes since the last report) | Every process |
| **Lessee table** | rows `pid → {last report, seen, grant}`; lessee `completed` and `timeouts` accumulated since the last step; `own_grant`; `last_total`; `last_min` | Owner only |

A **report**, whether from a lessee or the owner's own row, carries `in_flight`, `completed` since the last report, `timeouts` since the last report, `waiting` (queue length), `held_back`, and `probes` (path → delay). A report **wants** more when `waiting > 0 ∨ held_back`.

---

## 4. The algorithm

### 4.1 Admission record (the store-side contract)

Every body-carrying write asks the store's admission first and reports the outcome after:

```
acquire(bytes)            -- suspends until admitted, or fails with Stopping
... send the body (the driver may retry internally) ...
on answer:  completed(bytes, elapsed)   -- elapsed measured from after acquire
on failure: abandoned(bytes)
```

**Obligations on the caller.** Report exactly once for every body that was admitted. Never report a body that was never admitted (§8 gap 2). If a body leaks without a report, its bytes stay in flight and can close the window for good. `try_admit(bytes)` answers "would `acquire` pass right now", with no side effects on the budget. A caller that gets `true` must call `acquire` before it yields (A8). Only then is the room guaranteed.

Reads are never gated. A disabled link admits everything at once, and so does a Foreground class. All stores use Background.

### 4.2 Budget: token bucket plus in-flight window

The budget is pure: it is handed `now` at every call.

```
burst  = share_rate · BURST_SECONDS                       -- depth
window = share_rate · STALL_TIMEOUT · WINDOW_SAFETY       -- bytes allowed in flight

refill(now): if now > filled_at:
                 tokens = min(burst, tokens + share_rate·(now − filled_at)); filled_at = now
asks(b)      = min(b, burst)
admits(b)    = refill; tokens ≥ asks(b) ∧ (in_flight = 0 ∨ in_flight + b ≤ window)
take(b)      = refill; tokens −= b; in_flight += b        -- tokens may go negative
release(b)   = in_flight = max(0, in_flight − b)
wait_for(b)  = refill; ∞ if window blocks; else max(0, (asks(b) − tokens)/share_rate)
set_rate(r)  = refill at old rate; share_rate = max(1, r); tokens = min(tokens, new burst)
```

- **Oversize bodies.** A body larger than the bucket needs only a full bucket. The excess becomes debt, which is paid off before anything else passes. The long-run rate therefore holds whatever the body sizes.
- **The window bounds the backlog time.** Everything in flight crosses the link in at most `STALL_TIMEOUT·WINDOW_SAFETY` (30 s) at the granted rate, so the last body in line arrives well inside the stall detector (G5).
- **One body always goes alone.** When nothing is in flight, one body is admitted however large it is. A body larger than the window would otherwise never go.
- **Rate changes.** A rate change keeps the tokens already earned but not more than the new depth. A cut never leaves a bucket deeper than the new rate allows.

### 4.3 Gate: FIFO line with bounded overtaking

```
room(b) = (queue empty ∨ (b ≤ SMALL_BODY ∧ overtaken + b ≤ head.bytes)) ∧ budget.admits(b)

acquire(b):
  if room(b):                                     -- no suspension between check and take
      if queue nonempty: overtaken += b
      budget.take(b); return
  held_back = true
  enqueue (b, waker); arm(); suspend

pump():  while head exists ∧ budget.admits(head.bytes):
             pop; overtaken = 0; budget.take(head.bytes); wake(head)
arm():   if not armed ∧ head exists:
             w = budget.wait_for(head.bytes)
             if w < ∞: armed = true; after max(w, 1 ms): armed = false; pump(); arm()
             -- w = ∞ (window full): only a completion can help, and it pumps
left(b, answered, elapsed):                      -- completed/abandoned
  budget.release(b); if answered: completed_since += b; law.completed(b, elapsed)
  pump(); arm()
fail_waiting(exn):  wake every queued waiter with exn, having taken nothing; overtaken = 0
```

- **Ordering.** Admission order is FIFO. A small body (≤ 64 KiB) may pass a waiting head, but the bytes that pass one head add up to at most that head's size. A run of small bodies can delay a chunk by at most about twice its own transfer time (G7).
- **Timers.** One timer at most. A refill-bound head is woken by the timer, and a window-bound head is woken by the completion that frees space. Every rate change is followed by `pump` and `arm` (§4.6).
- **Demand.** `held_back` records that some body had to wait (or was refused by `try_admit`) since the flag was last read. It is the governor's only demand signal.

`try_admit(b)`: if the link is disabled, or the class is Foreground, answer true. Otherwise start the ticker if needed. If `room(b)`, answer true. If not, set `held_back`, add 1 to the law's `drops`, and answer false. A best-effort forward that is refused is dropped by the caller and fetched later by another mechanism. It is never held in memory.

### 4.4 The control law

The law is pure and handed `now`. It takes these inputs:

- `completed(bytes, elapsed)`: spreads `bytes` evenly over `max(1, ⌈elapsed⌉)` one-second cells ending now. A 40 s body counts as 40 s of throughput, not a 1 s burst followed by nothing.
- `observe_delay(path, d)`: appends a sample.
- `timed_out()`.
- `tick(now, limited)`, called every `TICK` (2 s).

Derived: `achieved = sum(completed cells over RATE_WINDOW) / RATE_WINDOW`.

**Signal filter (inside each tick):**

```
if no samples: queueing = ½·queueing                               -- decay, not hold
else:
  for each (path, d): base[path].note_min(now, d)                   -- 10 × 60 s cells
                      above(path, d) = max(0, d − base[path].min)
  current  = min over samples of above(...)
  queueing = ½·queueing + ½·current
samples = []
```

- **Per-path baselines.** A store twice as far away as another would otherwise read its extra distance as a queue.
- **Minimum across paths.** Queueing at the shared bottleneck shows on every path. Extra delay on only one path lies beyond the bottleneck (in that server or its network), and backing off would not help it.
- **Baseline scope.** The baseline includes the current sample, so `above ≥ 0`. A baseline that has not been refreshed for `BASE_WINDOW` (10 min) expires.

**Controller (one tick).** Let `T = target_delay`, `q = queueing`, `C = capacity`, `h = headroom`, `g = GAIN`:

```
over_target = (q > T) ? over_target + 1 : 0
off         = clamp((T − q)/T, −1, 1)              -- +1 = no queue, −1 = queue ≥ 2T
limited     = limited ∧ achieved > 0               -- demand AND bytes are moving (G4)

case phase of
 Ramping:                                          -- ceiling lifted
   if q > T ∧ over_target ≥ 2:                     -- the edge, confirmed on two ticks
       step = never_saturated ? 2 : 1+g;  never_saturated = false
       est  = rate / √step                         -- geometric mean of the last two steps
       if achieved > 0: est = min(est, 2·achieved)
       C    = max(achieved, est)                   -- REPLACES the old estimate
       enter Steady;  next = max(rate·DECREASE_FLOOR, h·C)
   elif q ≤ T/2 ∧ limited: next = rate · (never_saturated ? 2 : 1+g)
   else:                   next = rate
 Steady:
   if q ≤ T: settled = true
   elif settled ∧ over_target ≥ 2 ∧ achieved > 0:
       C = min(C, achieved)                        -- someone else took a share
   if now − since ≥ PROBE_UP_EVERY: enter Ramping  -- periodic ceiling lift
   next = (off > 0 ∧ ¬limited) ? rate : rate·(1 + g·off)     -- ×[0.75, 1.25]
 BackingOff:
   if now − since ≥ BACKOFF_HOLD: enter Ramping
   next = rate

ceiling = (phase = Ramping ∨ C unknown) ? ∞ : h·C
rate    = clamp(min(next, ceiling), min_rate, max_rate)

timed_out():  if achieved > 0: C = min(C, achieved)
              never_saturated = false; enter BackingOff
              rate = clamp(min(rate·DECREASE_FLOOR, ceiling))
enter(p):     phase = p; since = now; settled = false
```

**Reported limit.** The law reports what currently holds the rate:

- `Configured` when `rate ≥ 0.999·max_rate`;
- otherwise `Measured` when `C` is known;
- otherwise `Estimating`.

### 4.5 Process modes and the lease protocol

Each process has one mode, and the mode applies to every link at once. A process configures itself once, before it builds its first store:

- **Owner.** The daemon declares itself owner before its engines start and before it serves its socket, so a lessee never reaches a socket that has nobody answering. An owner runs each link's law, splits the law's rate among the parties, and answers renewals.
- **Leased.** A forked frontend or a command beside the daemon is given a send function to the daemon's socket, with a 1 s timeout per request. It runs no law and admits at its grant.
- **Local.** This is the default when there is no daemon. The process runs each link's law and admits at the law's rate.

**Renewal (lessee → owner).** One request per tick carries one report for each non-dormant link. The `completed`, `timeouts` and `held_back` fields are read and cleared when the report is built:

```
{pid, links: {name: report}}  →  {ok, interval, links: {name: {rate, limit?}}}
```

A lessee receives each answer as follows:

- **Granted.** Clear `missed`, adopt `interval`, and call `set_rate` on each named link's budget. A link the answer does not name keeps its last grant. Mode becomes Leased.
- **Refused.** The daemon answered, but without per-link grants: an old build, or it is not the owner. A Leased process drops to Local at once.
- **Unreached.** The request errored or timed out. Increment `missed`. When `missed ≥ 3`, a Leased process drops to Local.
- **In any case.** Pump and arm every link.

A Local process that has a daemon channel retries every 30 s. It sends the report the same step just built, so it does not claim to be idle.

**Owner, on a renewal.** For each link named in the renewal:

- Create the link on the owner's settings if the owner has never seen it. Its law then runs only on lessee-reported probes.
- Record the report and stamp `seen`.
- Accumulate the report's `completed` and `timeouts` for the next step.
- Feed its probe samples to the law as `observe_delay`, keyed by store name, so that one store has one baseline across processes.
- Reply with `rate_for(pid)`: the grant from the last split, or, for a newcomer, `max(min_rate, last_total/(1 + live_lessees))`. The newcomer is already counted in `live_lessees`, and the `1 +` is the owner's own row. A job started beside the daemon therefore starts at an even share (G6).

**Split (max-min fair, water-filling).** The owner's own report is one row, and each live lessee is another:

```
cap(r) = wants(r)        → ∞
         r.in_flight > 0 → max(min_rate, 1.25 · r.completed / TICK)
         otherwise       → min_rate
sort rows by cap ascending; remaining = total; left = n
for each row: share = max(min_rate, min(cap, remaining/left)); remaining = max(0, remaining − share); left −= 1
extra = remaining / n;   grant = share + extra                     -- unused rate still handed out
for each lessee row: held_back = false                             -- spent by this split
own budget.set_rate(own grant)
```

**Liveness.** A lessee row is dropped after `3·interval + PROBE_TIMEOUT` of silence (16 s). A lessee probes before it renews, so on a congested link its renewals can be spaced out by up to one probe timeout.

### 4.6 The step (Owner and Local, per non-dormant link, every TICK)

```
own_timeouts = Σ probes.timeouts() − last_timeouts;  last_timeouts = Σ
(lc, lt) = lessee table drain (Owner) else (0, 0)
if own_timeouts + lt > 0: law.timed_out()           -- one cut however many timeouts
if lc > 0: law.completed(lc, elapsed = TICK)
lessees = live rows (one listing, used for probing, demand and the split)
if own in_flight + Σ lessee in_flight > 0:           -- never probe an idle link (billed)
    concurrently for each attached store not held down:
        d = time(probe) under PROBE_TIMEOUT; a timeout reads as d = PROBE_TIMEOUT; other errors drop the sample
    law.observe_delay(store, d) for each
mine    = own report (reads and clears held_back and completed_since)
limited = wants(mine) ∨ ∃ lessee: wants(lessee)
law.tick(now, limited)
Owner: split(total = law.rate, self = mine);  Local: budget.set_rate(law.rate)
pump(); arm()
```

Timeouts are summed only over the stores attached to this link, so a stall on another link does not cut this one.

A **Leased** process's tick is different. For each non-dormant link, it probes its own stores, but only while its own bytes are in flight. It builds its report, and then renews every link in a single request.

**Ticker.** There is one loop per process. It starts lazily, on the first `acquire`, `try_admit` or probe attachment of an enabled link, or when the process becomes owner. It sleeps for `interval` when Leased and for `TICK` otherwise, and it never stops by itself.

**Dormant links.** A link with no probes and no admissions (and, for an owner, no live lessees) is dormant. It is not stepped, reported or renewed. It is kept, so a returning user finds the law where it left it.

### 4.7 Shutdown

When a stop is requested, `fail_waiting(Stopping)` runs on every link. Each queued waiter fails having taken nothing. Its caller must treat the work as owed and still on disk, and must not retry it. Bodies already in flight finish or are cut by the rest of the shutdown, and their completions release the window as usual. No renewal says goodbye. The owner ages the row out 16 s later.

---

## 5. Properties and why they hold

### 5.1 Safety

- **S1 Admission never exceeds the budget.**
  - *Rate.* Over any interval `[t₀, t₁]`, a process admits at most `burst + share_rate·(t₁ − t₀) + (one oversize body's debt)` bytes. Tokens are only earned by refill, and every take subtracts the full size.
  - *Window.* `in_flight ≤ max(window, largest single body)`, because a body passes only when the window has room or nothing is in flight.
  - *Atomicity.* Both depend on check-then-take being atomic. The gate's own `acquire` takes in the same turn as its check. `try_admit` followed by `acquire` is atomic only under A8. With preemptive threads, both need a single "try-take" primitive.
- **S2 No body waits forever while others pass.**
  - The head is displaced only by small bodies, and in total by no more than its own size.
  - Once `overtaken + b > head.bytes`, every newcomer queues behind the head.
  - A refill-bound head has an armed timer, and a window-bound head has bytes in flight whose completion or abandonment will pump.
  - The loophole is a leaked admission (A3 violated). The window then never reopens.
- **S3 Deliverability (G5).** In the worst case, a body is the last byte of a full window. At the granted rate it reaches the wire after `window/share_rate = STALL·SAFETY` (30 s), which is half the stall timeout.
  - *Rate cut.* A cut lowers `share_rate` below what was in force when the window filled. The cut shrinks the window for later admissions, and bodies already admitted drain at the link's real speed, not at the rate. The margin is the factor 0.5.
  - *Real speed below the rate.* This is the risk. The link may drain slower than the rate because capacity collapsed or because of foreign traffic. The resulting timeout is exactly the signal that cuts the rate (§5.3).
- **S4 Rate bounds.** After every tick, `min_rate ≤ rate ≤ max_rate` and `share_rate ≥ 1 B/s`.
- **S5 Growth only under demand (G4).**
  - *Ramping.* The rate grows only if some party was held back since the last step, and bytes completed in the last `RATE_WINDOW`.
  - *Steady.* A positive `off` raises the rate only under the same condition. A negative `off` always lowers it.
  - *Result.* An idle or trickling process holds its rate. Before this rule, a fresh daemon with light load reached terabytes per second within a minute (80b5e045).

### 5.2 Operating point and stability (single sender)

Model the bottleneck as a fluid queue that drains at the available capacity `A`, which is the link capacity minus foreign load. Queue delay grows at `(r − A)/A` seconds per second while `r > A`, and drains at `(A − r)/A` otherwise.

- **Equilibrium is at the ceiling, not at the target.**
  - Suppose capacity is known and `C ≈ A`. The ceiling `h·C < A`, so arrivals are below service and the queue drains toward zero. `q → 0` gives `off → +1`, and the controller asks for growth (under demand). The ceiling clips the rate to `h·C`.
  - The steady state is therefore `r* = h·C` with near-zero queue, and the target `T` is not where the queue settles. `T` is the **alarm threshold** that tells the law a queue is building, and the headroom is the margin that keeps the queue from forming at all.
  - This differs from LEDBAT, whose equilibrium holds exactly `T` of standing queue.
- **Recovery from overshoot.** A capacity drop, an overestimate, or a new foreign flow gives `A < r`. The queue grows until `q > T`.
  - *Rate decay.* In Steady, each tick multiplies the rate by `1 + g·off`, which is at least `0.75` when the queue is at `2T` or more. The rate falls below `A` within `⌈log_{0.75}(A/r)⌉` ticks.
  - *Capacity update.* Once `q` has been at or below `T` since entering Steady (`settled`) and then stays above `T` for two ticks, `C := min(C, achieved)`. Under a standing queue, `achieved ≤ A`, since what completes is at most what the bottleneck served to this sender. So the ceiling becomes `h·A` or lower, and the operating point re-forms below the new `A`.
  - *Lyapunov argument.* Take the queue length as the Lyapunov function. It is non-increasing from the first tick at which `r < A`, and strictly decreasing at rate `A − r ≥ (1 − h)·A` once `r ≤ h·A`. The system is therefore globally attracted to the low-queue region. The limits are the `min_rate` floor (§5.6) and a lower bound on the probe interval.
- **Bounded ramp overshoot.**
  - *Size of the overshoot.* A ramp step only happens when `q ≤ T/2`. The end requires `q > T` on two consecutive ticks, and the EWMA with ½ weight lags about one tick. The rate at detection is at most `step^L` times the rate that first built a queue, with `L` about 2 to 3 ticks.
  - *First ramp.* The first ramp, with step ×2, can overshoot by 4 to 8 times. It is the analogue of slow start, and can leave a transient queue of a few seconds on a deep buffer.
  - *Later probes.* With step ×1.25, the overshoot is at most about 2 times, and usually ≤ 1.5.
  - *After the ramp.* Steady inherits the ramp's queue. Because `settled` is false until the queue has drained below `T`, that self-built queue is not taken for a foreign share.
- **Estimation bias.** The capacity estimate `rate/√step` is clamped to `[achieved, 2·achieved]`, so it cannot be read off a rate that no data ever met (80b5e045).
  - *High bias.* Detection lag biases the estimate high, by up to about `√step` when the true edge lies below the previous step.
  - *Low bias.* A sender with a single body in flight at a time offers far less than its rate, which can bias the estimate low.
  - *Absorption.* The headroom factor absorbs the high bias. A low bias is corrected by the next periodic ramp, which replaces `C` outright.
- **Limit cycle.** Under sustained demand, Steady switches to Ramping every `PROBE_UP_EVERY` (60 s), counted from entering Steady.
  - *Link at capacity.* The ramp climbs ×1.25 per tick from `h·C` until the queue is confirmed, which takes about 3 to 5 ticks. It re-measures `C` and returns to Steady.
  - *Cost.* A brief delay spike of the order of `(1.5·h·C − A)·(detection lag)`, once a minute. This is how G2's "discover a faster link" is paid for, and it corresponds to BBR's ProbeBW cycle.
  - *Link faster than `C`.* The ramp continues until it meets the new edge.
- **Timeouts.**
  - *Cut.* A timeout halves the rate (clipped to the ceiling after lowering `C` to `achieved`) and holds it for `BACKOFF_HOLD` (10 s). One cut is taken per step however many timeouts occurred.
  - *Ramp afterwards.* The ramp uses ×1.25 steps, since `never_saturated` is cleared.
  - *Unanswered probe.* A probe that does not answer within `PROBE_TIMEOUT` reads as a 10 s delay. The next Steady tick multiplies by 0.75, and two such ticks end a ramp.

### 5.3 Behaviour in specific situations

| Situation | Behaviour |
|---|---|
| **Idle link** | No bytes in flight, so there are no probes. `queueing` halves each tick toward 0, `limited` is false, and the rate holds. `C` is kept (it does not decay). Every 60 s Steady → Ramping lifts the ceiling, but without demand nothing grows. Base cells expire after 10 min. |
| **Burst after idle** | The bucket is full (2 s × rate). Up to that many bytes, and at least one body, go at once, then the refill pace applies, capped by the window. The first probe comes at most one TICK after bytes are in flight. If the baseline expired, the first sample *becomes* the baseline, so a queue already built by then is invisible until a lower sample arrives or the old one expires 10 min later (§8 gap 5). If the phase is Ramping, growth resumes ×1.25 per tick from the kept rate once bytes complete. |
| **Link gets faster** | Found by the next periodic ramp, at most about 60 s plus the ramp duration later. `C` is replaced by the new measurement. |
| **Link gets slower / foreign traffic appears** | The queue rises. In Steady the rate shrinks up to ×0.75 per tick, then `C := min(C, achieved)` after two confirming ticks. In Ramping the ramp ends and `C` is measured afresh. A loss-based foreign flow keeps the queue high, so tsync falls to `min_rate` (64 KiB/s) and stays there. That is scavenger behaviour, like LEDBAT. |
| **Foreign traffic leaves** | Delay falls and the rate climbs back toward the (lowered) ceiling. The ceiling itself is lifted only by the next periodic ramp, so recovery takes up to one probe interval. |
| **Stalled request** | Its bytes stay in flight. If the window is full, the line waits, woken by the eventual completion or abandonment, not by a timer. After the stall detector fires (60 s), the store's timeout count rises, and the next step halves the rate and backs off. Retries happen inside the request, so re-sent bytes are not re-admitted (§8 gap 3). The body's `elapsed` includes the stall, which lowers `achieved`, a conservative bias. |
| **Many small bodies** | Each costs its payload in tokens. Request overhead (headers, TLS records, the round trip) is not billed, so a flood of tiny writes is paced mainly by the request-level pools elsewhere, and `achieved` understates wire use. The delay signal still catches any queue they build. Small bodies overtake a queued chunk by at most the chunk's size. |
| **Mixed near and far stores** | Each store has its own baseline, and the controller reads the least queued, so a far store is not taken for a queue. A store held down by health is not probed. If all stores are held, samples stop and `queueing` decays (§8 gap 6). |
| **Shutdown** | Waiters fail at once with Stopping and take nothing (G8). In-flight bodies finish or are cut elsewhere. A lessee's grant is reclaimed by the owner's aging 16 s later. |
| **Daemon restarts** | Lessees get Unreached, and after three misses (about 6 to 9 s) they go Local, each running a fresh law from its own state. The law in a Leased process was not ticked while leased, so it restarts from wherever it last stood, often the initial rate. The new owner starts from scratch at 256 KiB/s, doubling. Local processes rejoin within 30 s. |

### 5.4 Multiple processes on one machine (G6)

- **One controller.** Exactly one law runs per link while an owner is reachable. Every other process admits at a grant.
- **Conservation.** Grants add up to `max(total, n·min_rate)` after a split. Between splits, a newcomer's provisional grant can push the sum above the total by one even share, for at most one tick.
- **Max-min fairness.** Water-filling gives max-min fairness over the stated caps. A party with a line (wants) gets an equal share of what the less demanding parties leave. A party that is moving bytes without a line gets 1.25 times its recent throughput, room to grow without sitting on an idle reservation. An idle party gets the floor, so its first body can go. The leftover is spread over all parties, so a waking party can burst without waiting a tick.
- **Measurement and demand.** Lessee probes and completions feed the owner's law, so the owner measures even a link it has no store on. `held_back` from any party enables growth, and it is consumed by one split so that a single wait is not counted repeatedly.

### 5.5 Multiple links

- **Independence.** Each link has its own law, budget, line, baselines and lessee table. Timeouts are attributed through each store's own counter, and probes are per store, so a cut on one link never touches another (A1).
- **One renewal.** A lessee carries every link in one renewal. An owner that has never heard of a link creates it on its settings for that name.
- **Overlap is not modelled.** Two differently named links that in fact cross the same bottleneck are two uncoordinated controllers. Each still yields to the other's queue, as two delay-based flows do (§5.6).

### 5.6 Fairness against other senders

- **Loss-based TCP** (browsers, other uploaders). Loss-based TCP drives the queue to the buffer's depth, and tsync reads that as a persistent queue and backs off to `min_rate`. It is deliberately less aggressive, a "lower-than-best-effort" sender, and does not starve interactive traffic (G1, G3).
- **Another tsync machine or a LEDBAT flow.**
  - *Shared signal.* Both see the same queue and both cut. Each lowers `C` to its own `achieved`, so each ceiling tracks its current share.
  - *No equal-split guarantee.* The split depends on who ramped last. The periodic ramps re-contest the link every minute, which gives each a chance to regain ground.
  - *Latecomer problem.* A late starter may take a queue that is already standing as its baseline and hold it there. This is LEDBAT's latecomer problem, and the 10 min baseline expiry both causes it and eventually drifts it away.
- **The `min_rate` floor.** The floor means tsync never fully yields. Against a saturating foreign flow it still contributes `min_rate` of load, a deliberate trade so that tsync always makes progress.

---

## 6. Failure, crash and resume

| Point of interruption | Effect |
|---|---|
| **Process crash while bodies wait** | The waiters disappear with the process. Their work is still owed by whatever queued it (upload queues, deferred jobs). No governor state survives, and none needs to. |
| **Crash with bytes in flight** | The server may or may not have the body. That is the store contract's problem (idempotent puts by content key), not the governor's. |
| **Lessee crashes** | Its row ages out after 16 s. Until then its grant is withheld from the others (§8 gap 7). |
| **Owner crashes** | Lessees fall to Local after three unanswered renewals. The restarted owner's law starts cold. Lessees rejoin on their 30 s retry and get an even share at once. |
| **Renewal times out once or twice** | The lessee keeps its last grant. This is safe, because a grant is only an admission rate. |
| **Owner of an older build** | A reply without per-link grants counts as a refusal, so the process goes Local immediately. |
| **Lessee of an older build** | It sends a flat, single-link report and is answered on the default link with a top-level rate. Its missing `held_back` is read as `in_flight > 0`. |
| **Probe errors** (other than a timeout) | Ignored. Store health is the retry loop's concern. |
| **Probe times out** | Read as a 10 s delay. |
| **Configuration changed** | The first configuration in a process wins. Settings change only on a process restart. |

Every operation is idempotent where it matters:

- Admission reports are counted once each (caller obligation).
- A lessee's `held_back` is spent by one split.
- Completed and timeout counts are deltas that are cleared as they are read.
- Timeouts are read as deltas against a stored sum, and attaching a store adds its existing count to that sum, so an old tally is not taken as fresh.

---

## 7. Parameters

| Parameter | Value | Effect | Trade-off |
|---|---|---|---|
| `enabled` (config) | true | Off admits everything at once, the behaviour before the governor existed. | — |
| `headroom` `h` (config) | 0.8, in (0,1] | Steady rate as a fraction of measured capacity. Sets both the queue-drain margin and link use. | Higher uses more of the link but drains a transient queue more slowly and absorbs less estimation bias. Lower leaves bandwidth idle. |
| `target_delay` `T` (config) | 50 ms (≥ 5 ms) | Alarm threshold on queueing delay. Ramp steps need `q ≤ T/2`, and a ramp ends at `q > T` twice. | Lower reacts sooner but mistakes probe jitter or server variance for a queue. Higher tolerates more lag for interactive traffic. |
| `min_rate` (config) | 64 KiB/s | Floor of the rate and of every grant. | The progress guarantee against the purity of yielding. It also sets how oversubscribed the grants can be (n·min_rate). |
| `max_rate` (config) | none | Hard ceiling. The reported limit is `Configured` when the rate reaches it. | A per-store cap is expressed as its own link with a `max_rate`. |
| `INITIAL_RATE` | 256 KiB/s | Starting rate for a new law. | Higher shortens the first ramp but risks a startup queue on a slow link. |
| `TICK` | 2 s | Control period, renewal period and probe period. | Shorter reacts faster but costs more billed probes (1 per store per tick while busy) and more IPC. |
| `GAIN` `g` | 0.25 | Proportional gain. The step per tick is ×[0.75, 1.25], and later ramp steps are ×1.25. | Higher reacts faster but overshoots more on each probe. |
| First ramp step | ×2 | Exponential start while the link has never been saturated. | The overshoot of the first ramp against the time to reach the link's scale. |
| Confirmation | 2 ticks over T | Required to end a ramp and to lower `C` in Steady. | One probe queued behind one body reads as a phantom queue (80b5e045). Two ticks add about 2 s of lag. |
| EWMA weight | ½ per tick | Queue-signal smoothing, and the decay when no samples arrive. | Smoothing against lag. |
| `DECREASE_FLOOR` | 0.5 | Multiplier on a timeout. At a ramp end it is meant as a floor but is dead (§8 gap 1). | — |
| `BASE_WINDOW` | 600 s (10 × 60 s cells) | Memory of the baseline minimum per path. | Longer is robust to self-induced queue but slow to follow route changes and prone to latecomer capture (LEDBAT uses about 10 min too). |
| `RATE_WINDOW` | 10 s (1 s cells) | `achieved` averaging. | Longer is smoother but reads a ramp's early seconds into the capacity. |
| `PROBE_UP_EVERY` | 60 s | Periodic ceiling lift in Steady. | Shorter finds a freed link sooner but produces delay spikes more often. |
| `BACKOFF_HOLD` | 10 s | Hold after a timeout before ramping. | — |
| `PROBE_TIMEOUT` | 10 s | Limit on a probe. An unanswered probe reads as this delay. Adds to the lessee aging period. | — |
| `BURST_SECONDS` | 2 s | Bucket depth in seconds of rate. | Deeper passes bursts through without waiting but puts a bigger burst into the bottleneck. |
| `STALL_TIMEOUT` | 60 s | The transport's stall detector. It is the same setting the drivers use, so the window and the deadline stay consistent. | — |
| `WINDOW_SAFETY` | 0.5 | Fraction of the stall timeout that the in-flight backlog may take to cross. | Lower means fewer timeouts and fewer bodies in flight (less pipelining). |
| `SMALL_BODY` | 64 KiB | Largest body allowed to overtake the queue. | Covers cursor and journal writes. |
| Lessee cap factor | 1.25 × recent use | Room a non-waiting mover gets. | — |
| Lessee aging | 3·interval + PROBE_TIMEOUT (16 s) | Time before a silent lessee's share is reclaimed. | — |
| Missed renewals before Local | 3 | — | Tolerance of a slow daemon against the time spent at a stale grant. |
| Renewal timeout | 1 s | — | — |
| Local retry | 30 s | Rediscovery of a daemon. | — |

---

## 8. Known gaps

1. **The decrease floor at a ramp end is dead.** `next = max(rate·0.5, h·C)` is then clipped by `min(next, ceiling = h·C)`, so the rate always lands on `h·C`, however far below `rate/2` that is. `h·C` is bounded below by `h·achieved`, which is sane, but the floor as written has no effect. A correct version clips the floor by the ceiling explicitly (or drops it).
2. **Foreground and disabled admissions release bytes they never took.** For those classes, `acquire` returns without `take`, but `completed`/`abandoned` still `release` from the shared in-flight count (clamped at 0) and feed `completed` to the law. A Foreground body completing while Background bodies are in flight would under-count the in-flight bytes and let the window overfill. This is latent, since nothing uses Foreground. A correct version routes release through whichever branch took.
3. **Retries are not re-admitted.** A driver's internal retry re-sends the body without asking the budget. `elapsed` includes backoff sleeps. When the link is faulty, the true upload volume exceeds the admitted volume. A correct version admits each attempt, or at least bills retransmissions.
4. **Request overhead is not billed.** Tokens are payload bytes only (§5.3, many small bodies).
5. **The baseline is sampled only under the process's own load.** Probes are sent only while bytes are in flight, so the baseline minimum always includes whatever queue the sender (and foreign traffic) had at the time. After the baseline expires (10 min), a queue that has stood the whole time *becomes* the baseline, and tsync stops yielding to it. This is the classic LEDBAT base-drift and latecomer failure. Mitigations would include an occasional probe while idle (at a billed cost), a longer expiry, or taking the baseline from the minimum over a quiet period.
6. **No samples reads as "no queue".** A tick with no samples halves `queueing`. That happens when every store is held down, when an owner's only samples come from lessees whose renewals miss a tick, or when bytes are in flight only between ticks. The bias is toward growth. Holding the last value, or decaying only after N empty ticks, would be neutral.
7. **Grants of dead lessees linger 16 s.** Nothing says goodbye. The aggregate is conservative (under-use), not unsafe.
8. **The floor oversubscribes.** Each party gets at least `min_rate`, so n parties can be granted more than the law's rate. A newcomer's provisional share also oversubscribes until the next split.
9. **No persistence.** Every daemon start re-ramps from 256 KiB/s with ×2 steps. The first ramp's overshoot (§5.2) recurs on every restart.
10. **Clock.** The law and budget use a monotonic clock, but the transport's stall detector and store health use wall time. A forward wall-clock step can fire spurious stall timeouts, which the governor reads as a halving (findings **G12**).
11. **Atomicity rests on cooperative scheduling.** `try_admit` then `acquire`, and all mutations of the gate, budget and law from callbacks, timers and the ticker, are atomic only under A8 (06 §6.1 items 1–2). A preemptive port needs a single try-take and one lock per link.
12. **The probe measures more than the bottleneck.**
    - Server time, a local connection-pool wait, and the probe's own retry ladder all land in `d`.
    - The signal is round-trip, so a saturated *downlink* also reads as queue, and uploads slow for a download. This is conservative, but it is not what G1 targets.
13. **The capacity estimate has no decay.** A `C` measured long ago persists through idle periods. It is corrected only by the next ramp end (replace) or a confirmed queue (lower). This is harmless, because the next periodic ramp re-measures.

None of these appears in `findings.md` except G12. Gaps 1, 2 and 5 are the ones a reimplementation should fix rather than copy.

---

## 9. Alternatives and rationale

- **Throughput caps (a fixed per-store `maxUploadRate`).** This was the first gate (3c3851d6). A fixed number is wrong on every link but one: "two megabytes a second is all of a small pipe or half of a large one" (06 §7 item 20). The option was removed in the same series. The per-store budget mechanism (`capped`, `compose`) survives only in tests (06 §9 item 1). A per-store ceiling is now expressed as a link of its own with a `max_rate`.
- **LEDBAT** (RFC 6817) is the model (c548cc2d): delay above a minimum-filtered baseline, a fixed target, grow below and shrink above, cut on loss. It differs from LEDBAT as follows:
  - *Rate, not window.* The unit is bodies of MiB over HTTP, with no per-ACK clocking, so the law adjusts a rate every 2 s.
  - *Operating point.* The equilibrium is at `h·C` with a near-empty queue, not at a standing `T`.
  - *Headroom and capacity estimate.* Pure LEDBAT is known to drift. The estimate, and its replacement by each ramp, is borrowed from BBR's idea.
  - *Periodic probing.* Pure LEDBAT at equilibrium never learns that the link got faster, because the probe that would reveal it is the growth it withholds.
  - *Per-path baselines and min across paths*, for stores at different distances (9dcc26c7).
- **TCP Vegas.** Vegas compares expected with actual throughput, `diff = (rate − achieved)·baseRTT`, and holds α…β packets queued. The governor's `achieved` bounds on the capacity estimate play a similar role (what got through versus what was offered). Vegas's additive per-RTT steps would be far too slow at a 2 s control period, so the governor uses multiplicative steps.
- **BBR.** Similar ideas: an explicit bottleneck-bandwidth estimate, pacing below it (headroom resembles a pacing gain < 1), and periodic probing up (the 60 s ramp resembles ProbeBW), plus a minimum-RTT baseline with expiry (ProbeRTT resembles the 10 min baseline window). The differences are that BBR takes bandwidth as a windowed max of delivery rate at ACK granularity, and it competes with loss-based flows instead of yielding to them. Yielding is a goal here (G3).
- **AIMD.** Additive increase does not scale over the three orders of magnitude between links (64 KiB/s to 100 MB/s) at a 2 s period. Multiplicative increase and decrease (MIMD, ×[0.75, 1.25]) is scale-free but not fair between competing instances by itself. On one machine fairness comes from the owner's split. Between machines it comes from each sender lowering `C` to its own achieved share.
- **Kernel-level alternatives.**
  - *Kernel congestion control.* An OS LEDBAT congestion controller does not exist on Linux, and HTTP client libraries do not expose it.
  - *Pacing sockets.* `SO_MAX_PACING_RATE` with the fq qdisc could pace sockets, but it still needs someone to choose the rate. It also paces per socket, not per link across pools and processes.
  - *Local queue management.* Queue management in the router (fq_codel, CAKE) is the proper fix for bufferbloat, but the user's router is out of reach.
- **One law per process** (the design before 1ee2e4e2). N independent laws on one link each see the others' queue as foreign traffic and all back off to the floor. A new job also started cold. The alternative was an owner with lessees, one line per tick.
- **Probe choice** (16cdb6f0). A metadata read of the domain cursor exists on every written store and costs almost nothing. It is sent only while bytes are in flight, because probes are billed.
- **Specific fixes, with the commits that made them:**
  - Growth requires held-back demand (80b5e045: runaway to terabytes per second).
  - Growth also requires completing bytes, and completions are credited over their duration (859ecf1f: a long body read as a burst, which inflated the capacity).
  - The capacity estimate is bounded by 2× achieved (80b5e045: a single-body-in-flight sender read a link of a few MB/s as twenty).
  - A ramp ends only on two ticks over target (80b5e045: a phantom queue behind one body).
  - A lessee's held-back flag is spent once per split (80b5e045).
  - Timeouts are counted per member (4f0bc2ca).
  - Links are separate (a8c127c7), and one renewal carries every link (1ea95d84).
  - Small-body overtaking is bounded by the head's size (c3c4a983).
  - The lessee aging period includes the probe timeout (c3c4a983).
- **Pure, time-handed modules.** The budget, law and split never read a clock, so tests drive them on a fake clock and read each decision at a chosen instant (06 §7 item 21).

---

## 10. Mapping to the current implementation

Spec: [06 §4.9](../06-backends.md#49-the-uplink-governor), [06 §6](../06-backends.md#6-concurrency-durability--failure-semantics), [06 §7 items 16, 20, 21](../06-backends.md#7-design-choices--rationale-dont-undo-these), [06 §9 item 1](../06-backends.md#9-open-questions--inconsistencies), config in [05](../05-ops-config.md), IPC `uplink` action in [07](../07-daemon-cli.md), tests in [09 §A4.6](../09-tests.md).

| Abstract | Concrete |
|---|---|
| Admission record (§4.1) | `Uplink.admission` record `{acquire; completed; abandoned; now; waiting; try_admit}` in `lib/backends/uplink/uplink.ml`. Caller: `Backend.counted`'s `governed` (`lib/backends/api/backend.ml`), wrapping `put`/`put_if_absent`. Unwired stores use `ungated`. |
| Store → link wiring, probe attach | `Domain.admission_for` (link from a backend's `link` field, default `"wan"`, class `Background`); `Domain.attach_probe` (`head_opt cursor_key`, `held = Health.is_held`, `timeouts = Health.timeouts`; skipped when `local_path` is set), in `lib/domain/config/domain/domain.ml` |
| Best-effort forward's `try_admit` | deferred target `room_for` = the store's admission `try_admit` (06 §4.4) |
| Budget (§4.2) | `Uplink_budget` (`create`, `admits`, `take`, `release`, `wait_for`, `set_rate`, `window_bytes`). Constants `stall_timeout` = 60, `window_safety` = 0.5, `burst_seconds` = 2. The GCS driver's request timeout reads `stall_timeout`. |
| Gate (§4.3) | `Uplink.Make.gate` / `room` / `acquire` / `pump` / `arm` / `left` / `fail_waiting`; `small_body` = 65536 |
| Law (§4.4) | `Uplink_control` (`tick`, `read_delay`, `completed`, `observe_delay`, `timed_out`, `measured_capacity`, `lower_capacity`, `ceiling`, `limit`). The ring buffers are `Uplink_control.Window`. Constants: `initial_rate`, `tick_interval`, `probe_timeout`, `gain`, `decrease_floor`, `base_window`, `rate_window`, `probe_up_every`, `backoff_hold`. |
| Settings | `Uplink_control.settings` / `default_settings`; config `uplink` and `links.<name>` (`Conf_parsing.uplink_of_json`, `link_settings`), applied through `Uplink.configure` (first writer wins) |
| Report, split, lessee table (§4.5) | `Uplink_lease` (`report`, `wants`, `can_use`, `water_fill`, `split`, `live`, `rate_for`, `drain`, `record`, `report_of_json`/`report_to_json`) |
| Process, modes, ticker, step, renewal (§4.5–4.6) | `Uplink.Make`: `process`, `mode`, `own`, `lease_through`, `lease_renewal`, `renew`, `read_answer`, `answer_json`, `fall_to_local`, `maybe_retry`, `ticker`, `ensure_ticking`, `step`, `probe_round`, `own_report`, `timeouts_since`, `dormant`. Constants `retry_every` = 30, `missed_before_local` = 3. |
| Lwt instantiation, shutdown, IPC | `lib/lwt/core/uplink_lwt.ml`: `own_links`, `lease_from ~socket_path` (1 s `Ipc_lwt.send_lwt` timeout), `Shutdown.on_request → cancel_waiting … Stopping`. The daemon's sync-socket `{"action":"uplink"}` handler calls `lease_renewal` (07 §3.6). |
| Timeout counter (A9) | `Health.timed_out` / `Health.timeouts`, fed by `Retry.with_retry` (06 §4.1) |
| Stall detector (A2) | `Http_client` `timeout` via `Clock.with_stall_timeout` (wall clock, findings G12) |
| Status | `Uplink.json` / `json_links` (fields listed in 06 §4.9 "Status JSON") |
| Tests | `tests/unit/{uplink_budget,uplink_control,uplink_lease,uplink_modes,uplink,backend_capped}`; the control-law test drives the law against a simulated fluid link on a fake clock |
| Dead | `Uplink.capped`, `Uplink.compose` (tests only), class `Foreground` (unused) |
