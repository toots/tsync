# The uplink governor

A delay-driven rate controller for background uploads over a shared network link. It has a token-bucket admitter in every process, and a lease protocol that splits one controller's rate among the processes of one machine. The store-side seam it is reached through is [06-backends.md](../06-backends.md) (admission); its configuration is [06-backends.md](../06-backends.md) (uplink configuration).

"The store" means any remote object store reached over a network path. "A body" means one upload attempt's payload. "The link" means a named network path that several stores may share.

---

## 1. Problem and goals

tsync uploads file content in the background: chunk bodies of several MiB, and small metadata bodies. The upload link is usually a consumer uplink with a deep buffer in the modem or router, and the user is on the same link. A sender limited only by TCP fills that buffer, and every interactive flow on the link then waits behind seconds of queued upload.

The control problem: **choose a send rate `r(t)` per link so that the link is used near its free capacity while the standing queue at the bottleneck stays near zero.** The only observation available is the round-trip delay of small requests.

Goals:

- **G1 Low standing queue.** In steady state, the queueing delay tsync adds stays below a small target. Transients above it are bounded in size and length.
- **G2 Use the link.** When nobody else wants the link, the rate approaches a fixed fraction (`headroom`) of what the link was measured to carry, and it discovers a link that got faster.
- **G3 Yield.** When other traffic takes a share, the rate falls to what is left, down to a floor, and recovers within about one probe period when that traffic leaves.
- **G4 No wind-up.** A sender with little to send does not accumulate permission it has never used.
- **G5 Deliverability.** An admitted body can finish before the transport's stall detector gives up on it.
- **G6 One controller per link per machine.** The processes of one machine run one controller per link between them, and a process started beside others does not start cold.
- **G7 Small bodies are not starved.** Cursor and journal writes may pass a queued chunk, but only by a bounded amount.
- **G8 Stop quickly.** At shutdown, bodies waiting for admission give up at once and stay owed on disk.
- **G9 Warm restart.** A restarted controller does not rediscover a known link from scratch.

Non-goals:

- **Downloads are never gated.** A read has a user waiting on it.
- **No fairness guarantee between machines.** Each machine runs its own controller. Fairness between them is only emergent (§5.6).
- **Not a transport congestion controller.** Loss recovery and TCP's window stay with the kernel. The governor limits only the arrival rate of bodies into TCP.
- **No per-store rate caps.** A per-store ceiling is a link of its own with a `maxRate`.

---

## 2. System model and assumptions

- **A1 One bottleneck per link.** All stores naming one link share one bottleneck queue. Different links are independent paths, and a store sits on exactly one link. Stores on one link may be at different network distances, so each has its own base round-trip time.
- **A2 Bodies are opaque and sent whole.** An upload attempt is one request, answered only after the whole body arrived. The transport's timeout is a **stall detector**: it fires after STALL_TIMEOUT with no byte of the *answer*, and request-side progress does not reset it. A body queued behind others spends its whole wait inside its own timeout.
- **A3 Completion is observable per attempt.** For every admitted attempt the sender learns once whether it was answered, and after how long, or abandoned. Every attempt, retries included, is admitted ([06-backends.md](../06-backends.md) admission seam).
- **A4 Delay is observable only by probing.** The signal is the round-trip time of a small, idempotent metadata read of a key every store holds (the domain cursor). It carries the bottleneck's queue on the request path, plus propagation, plus server time. Probes are billed requests, so they are sent only while bytes are in flight.
- **A5 Foreign traffic is invisible except through delay.**
- **A6 Monotonic clock.** Every duration and rate uses a monotonic clock (P5). Stored timestamps use the wall clock.
- **A7 Local request interface.** Processes on one machine reach the governor owner with a short request and response. The owner may be absent, restarting, or of an older build.
- **A8 Timeouts are counted per store.** Each store keeps a monotonically increasing count of its attempts that hit the stall detector.
- **A9 Crashes lose no data.** An upload that never ran is still owed by whatever queued it. Governor state is advisory: losing it costs only rate knowledge.

---

## 3. State

**Per process:**

- `mode ∈ {Owner, Leased, Local}`, the same for all links.
- `missed`: renewals left unanswered in a row.
- `retry_at`: when a Local process next tries to lease or to become owner.
- `interval`: the renewal period dictated by the owner.
- `settings`: defaults and per-link overrides, fixed at the first configuration.
- `links`: a map from name to link, each created on first mention.

**Per link:**

| Part | State | Lives in |
|---|---|---|
| **Law** | `rate`; `phase ∈ {Ramping, Steady, BackingOff}`; `since`; `settled`; `over_target`; `never_saturated`; `capacity C` (optional); `queueing` (EWMA); pending `samples` (path, delay); per path a sliding minimum over BASE_CELLS × BASE_CELL and an effective baseline `eff[path]` with the time it last changed; `completed`, a sliding sum over RATE_WINDOW in 1 s cells; `drops` | Owner and Local processes |
| **Budget** | `share_rate`; `tokens`; `filled_at`; `in_flight` | Every process |
| **Gate** | FIFO of (bytes, waker); `armed` (one timer at most); `overtaken`; `held_back` (read and clear) | Every process |
| **Probes** | per attached store: path name, is-held, timeout counter, probe action; `last_timeouts`; `completed_since` | Every process |
| **Lessee table** | rows `pid → {last report, seen, grant}`; accumulated lessee `completed` and `timeouts`; `own_grant`; `last_total` | Owner |

A **report**, whether a lessee's or the owner's own row, carries `in_flight`, `completed` and `timeouts` since the last report, `waiting` (line length), `held_back`, and `probes` (path → delay). A report **wants** more when `waiting > 0 ∨ held_back`.

**Saved state** (local, owner only): per link `{capacity, rate, saved_at}` (§4.7).

---

## 4. The algorithm

### 4.1 Admission

Every body-carrying upload attempt asks its store's admission first and reports once after:

```
t := acquire(bytes + REQUEST_OVERHEAD)          -- suspends until admitted, or fails STOPPING
... send the attempt ...
on answer:  completed(t, elapsed)                -- elapsed measured from admission
on failure: abandoned(t)

t := try_acquire(bytes + REQUEST_OVERHEAD)      -- best effort: admitted now, or refused; never waits
```

- `acquire` and `try_acquire` return an **admission ticket** recording what was taken. `completed` and `abandoned` release exactly what the ticket took. A ticket from a disabled link took nothing and releases nothing.
- `try_acquire` checks and takes in one atomic step. A refusal sets `held_back` and counts one drop.
- The caller MUST report every ticket exactly once. A leaked ticket keeps its bytes in flight and can close the window for good.
- REQUEST_OVERHEAD bills request headers, framing and the round trip, so a flood of tiny writes is paced too.
- A disabled link admits at once without touching the budget.

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
wait_for(b)  = refill; ∞ if the window blocks; else max(0, (asks(b) − tokens)/share_rate)
set_rate(r)  = refill at the old rate; share_rate = max(1 B/s, r); tokens = min(tokens, new burst)
```

- **Oversize bodies.** A body larger than the bucket needs only a full bucket. The excess becomes debt, paid off before anything else passes, so the long-run rate holds whatever the body sizes.
- **The window bounds backlog time.** Everything in flight crosses the link within `STALL_TIMEOUT · WINDOW_SAFETY` at the granted rate, so the last body in line arrives well inside the stall detector (G5).
- **One body always goes alone.** When nothing is in flight, one body is admitted however large it is.
- **Rate changes** keep the tokens already earned, but never more than the new depth.

### 4.3 Gate: FIFO line with bounded overtaking

```
room(b) = (queue empty ∨ (b ≤ SMALL_BODY ∧ overtaken + b ≤ head.bytes)) ∧ budget.admits(b)

acquire(b):
  if room(b):                                     -- check and take in one step
      if queue nonempty: overtaken += b
      budget.take(b); return ticket(b)
  held_back = true
  enqueue (b, waker); arm(); suspend

pump():  while head exists ∧ budget.admits(head.bytes):
             pop; overtaken = 0; budget.take(head.bytes); wake(head)
arm():   if not armed ∧ head exists:
             w = budget.wait_for(head.bytes)
             if w < ∞: armed = true; after max(w, 1 ms): armed = false; pump(); arm()
             -- w = ∞ (window full): only a completion can help, and it pumps
left(ticket, answered, elapsed):
  budget.release(ticket.bytes); if answered: completed_since += ticket.bytes; law.completed(ticket.bytes, elapsed)
  pump(); arm()
fail_waiting(kind):  wake every queued waiter with kind, having taken nothing; overtaken = 0
```

- **Ordering.** Admission is FIFO. A small body may pass a waiting head, but the bytes that pass one head add up to at most that head's size, so a run of small bodies delays a chunk by at most about its own transfer time (G7).
- **Timers.** One timer at most. A refill-bound head is woken by the timer, a window-bound head by the completion that frees space. Every rate change is followed by `pump` and `arm`.
- **Demand.** `held_back` records that some body had to wait, or was refused, since the flag was last read. It is the governor's only demand signal.

### 4.4 The control law

The law is pure and handed `now`. Inputs:

- `completed(bytes, elapsed)` spreads `bytes` evenly over `max(1, ⌈elapsed⌉)` one-second cells ending now. A 40 s body counts as 40 s of throughput, not a 1 s burst followed by nothing.
- `observe_delay(path, d)` appends a sample.
- `timed_out()`.
- `tick(now, limited, busy)`, called every TICK. `busy` says whether any party has bytes in flight.

Derived: `achieved = sum(completed cells over RATE_WINDOW) / RATE_WINDOW`.

**Signal filter (inside each tick):**

```
if no samples:
   if busy: queueing unchanged                      -- a missing sample is not evidence of no queue
   else:    queueing = ½·queueing                   -- idle: the queue drains
else:
   for each (path, d):
      cells[path].note_min(now, d)                  -- BASE_CELLS × BASE_CELL sliding minimum
      m = min(cells[path])                           -- the current sample included
      if m ≤ eff[path]: eff[path] = m
      else: eff[path] = min(m, eff[path] + BASE_MAX_RISE · (now − eff_changed[path]) / BASE_WINDOW)
      above(path, d) = max(0, d − eff[path])
   current  = min over samples of above(...)
   queueing = ½·queueing + ½·current
samples = []
```

- **Per-path baselines.** A store twice as far away as another would otherwise read its extra distance as a queue.
- **Minimum across paths.** Queueing at the shared bottleneck shows on every path. Extra delay on one path only lies beyond the bottleneck, and backing off would not help it.
- **Bounded baseline rise.** The minimum forgets samples older than BASE_WINDOW, so a queue that stood for the whole window would otherwise become the new baseline at once, and the sender would stop yielding to it. The effective baseline follows a lower minimum at once, but rises by at most BASE_MAX_RISE per BASE_WINDOW. A real path change is adopted gradually, in the conservative direction (the sender reads the extra delay as queue and slows down meanwhile). A standing foreign queue is absorbed only slowly, and each rise is conditional on the queue still being there.

**Controller (one tick).** Let `T = target_delay`, `q = queueing`, `h = headroom`, `g = GAIN`, `r = rate` before the tick:

```
over_target = (q > T) ? over_target + 1 : 0
off         = clamp((T − q)/T, −1, 1)              -- +1 = no queue, −1 = queue ≥ 2T
limited     = limited ∧ achieved > 0               -- demand AND bytes are moving (G4)

case phase of
 Ramping:                                          -- ceiling lifted
   if q > T ∧ over_target ≥ 2:                     -- the edge, confirmed on two ticks
       step = never_saturated ? 2 : 1+g;  never_saturated = false
       est  = r / √step                            -- geometric mean of the last two steps
       if achieved > 0: est = min(est, 2·achieved)
       C    = max(achieved, est)                   -- replaces the old estimate
       enter Steady;  next = h·C
   elif q ≤ T/2 ∧ limited: next = r · (never_saturated ? 2 : 1+g)
   else:                   next = r
 Steady:
   if q ≤ T: settled = true
   elif settled ∧ over_target ≥ 2 ∧ achieved > 0:
       C = min(C, achieved)                        -- someone else took a share
   if now − since ≥ PROBE_UP_EVERY: enter Ramping  -- periodic ceiling lift
   next = (off > 0 ∧ ¬limited) ? r : r·(1 + g·off)     -- ×[0.75, 1.25]
 BackingOff:
   if now − since ≥ BACKOFF_HOLD: enter Ramping
   next = r

ceiling = (phase = Ramping ∨ C unknown) ? ∞ : h·C
rate    = clamp(max(min(next, ceiling), r·DECREASE_FLOOR), min_rate, max_rate)

timed_out():  if achieved > 0: C = min(C, achieved)
              never_saturated = false; enter BackingOff
              rate = clamp(r·DECREASE_FLOOR, min_rate, max_rate)
enter(p):     phase = p; since = now; settled = false
```

- **Decrease floor.** No tick lowers the rate by more than DECREASE_FLOOR. A ramp end, a lowered capacity, or a timeout that leaves the rate far above the new ceiling brings it down over a few ticks, halving at most each time. A single noisy tick therefore cannot collapse the rate, and a real queue still takes it down geometrically.
- **One timeout cut per step**, however many timeouts occurred (§4.6).

**Reported limit.** `Configured` when `rate ≥ 0.999·max_rate`; otherwise `Measured` when `C` is known; otherwise `Estimating`.

### 4.5 Governor ownership and the lease protocol

One process per machine is the **governor owner**. It runs each link's law, splits each law's rate among the processes using the link, and answers renewals.

- The machine-level supervisor, when there is one, is the governor owner ([07-daemon-cli.md](../07-daemon-cli.md)). Otherwise the owner is whichever process holds the machine-wide governor lock, an exclusive local lock that the kernel drops when its holder dies.
- A process becomes owner before it builds its first store, and before it serves its request interface, so a lessee never reaches an interface with nobody answering.
- Every other process with links is **Leased**. It sends one renewal per tick to the owner, with a RENEWAL_TIMEOUT, runs no law, and admits at its grant.
- A process is **Local** when no owner answers: it runs each link's law itself and admits at the law's rate. Every LOCAL_RETRY it first tries to take the governor lock (and becomes owner if it can), then tries to lease.

**Renewal (lessee → owner).** One request per tick carries one report per non-dormant link. `completed`, `timeouts` and `held_back` are read and cleared when the report is built.

```json
→ {"action":"uplink","pid":1234,"links":{"wan":{"inFlight":8388608,"completed":16777216,"timeouts":0,
     "waiting":3,"heldBack":true,"probeMs":41.2,"probesMs":{"gcs":41.2,"s3":55.0}}}}
← {"ok":true,"interval":2.0,"links":{"wan":{"rate":1250000.0,"limit":"measured"}}}
```

- `probesMs` maps store name → delay in ms. `probeMs`, the least of them, is sent too.
- Readers MUST accept the older shapes. A report without `links` is a single-link report for the link `"wan"`, with its fields at top level, and is answered with a top-level `"rate"` as well as `links`. A report without `heldBack` has `held_back = inFlight > 0`. A report without `probesMs` has a single probe under the empty path name, with the value of `probeMs`.
- An answer without `links` is a refusal.

A lessee takes each answer as follows:

- **Granted.** Clear `missed`, adopt `interval`, and `set_rate` each named link's budget. A link the answer does not name keeps its last grant. Mode becomes Leased.
- **Refused.** The owner answered without per-link grants (an older build, or not the owner): drop to Local at once.
- **Unreached.** The request failed or timed out: increment `missed`. At `missed ≥ MISSED_BEFORE_LOCAL`, drop to Local.
- **In any case**, pump and arm every link.

A Local process that tries to lease sends the report its step just built, so it does not claim to be idle.

**Owner, on a renewal**, for each link named:

- Create the link on the owner's settings if it has never seen it. Its law then runs on lessee-reported probes only.
- Record the report and stamp `seen`. Accumulate its `completed` and `timeouts` for the next step.
- Feed its probe samples to the law as `observe_delay`, keyed by store name, so one store has one baseline across processes.
- A pid not in the table is a newcomer: run the split at once with it included, set the owner's own budget to its new grant, and answer the newcomer with its share. Other lessees adopt the new split at their next renewal.
- Otherwise answer with the pid's grant from the last split.

**Split (max-min fair, water-filling).** The owner's own report is one row, and each live lessee another. With `total` the law's rate and `n` the number of rows:

```
floor  = min(min_rate, total / n)                  -- floors fit inside the link's rate
cap(r) = wants(r)        → ∞
         r.in_flight > 0 → max(floor, 1.25 · r.completed / interval)
         otherwise       → floor
sort rows by cap ascending; remaining = total; left = n
for each row: share = max(floor, min(cap, remaining/left)); remaining = max(0, remaining − share); left −= 1
extra = remaining / n;   grant = share + extra     -- unused rate is still handed out
for each lessee row: held_back = false              -- spent by this split
own budget.set_rate(own grant)
```

After a split, grants add up to exactly `total`. Between splits, a newcomer's share can oversubscribe by at most that share, for at most one renewal interval.

**Lessee liveness.** The owner drops a lessee row at its next step when the pid no longer exists on the machine, and in any case after LEASE_TTL = `3·interval + PROBE_TIMEOUT` of silence (a lessee probes before it renews, so its renewals can be spaced out by one probe timeout).

### 4.6 The step (Owner and Local, per non-dormant link, every TICK)

```
own_timeouts = Σ probes.timeouts() − last_timeouts;  last_timeouts = Σ
(lc, lt) = lessee accumulators drained (Owner) else (0, 0)
drop lessee rows whose pid is gone or that are older than LEASE_TTL
if own_timeouts + lt > 0: law.timed_out()           -- one cut however many timeouts
if lc > 0: law.completed(lc, elapsed = TICK)
lessees = live rows
busy    = own in_flight + Σ lessee in_flight > 0
if busy:                                             -- never probe an idle link (billed)
    concurrently for each attached store not held down:
        d = time(probe) under PROBE_TIMEOUT; a timeout reads as d = PROBE_TIMEOUT; other failures drop the sample
    law.observe_delay(store, d) for each
mine    = own report (reads and clears held_back and completed_since)
limited = wants(mine) ∨ ∃ lessee: wants(lessee)
law.tick(now, limited, busy)
Owner: split(total = law.rate, rows = mine + lessees);  Local: budget.set_rate(law.rate)
pump(); arm()
```

- Timeouts are summed only over the stores attached to this link, so a stall on another link does not cut this one. Attaching a store adds its current count to `last_timeouts`, so an old tally is not read as fresh.
- A **Leased** process's tick probes its own stores (only while its own bytes are in flight), builds its report, and renews every link in one request.
- **Ticker.** One loop per process. It starts on the first admission, probe attachment or ownership, sleeps `interval` when Leased and TICK otherwise, and never stops by itself.
- **Dormant links.** A link with no probes and no admissions (and, for an owner, no live lessees) is not stepped, reported or renewed. It is kept, so a returning user finds the law where it left it.

### 4.7 Saved state and restart

- The governor owner saves, per link, `{capacity, rate, saved_at}` to a local file at most every STATE_SAVE_INTERVAL, and at an orderly stop. The file is written atomically (temporary file, then rename). It is advisory, so losing it costs only a cold start.
- A new law for a link with saved state younger than STATE_MAX_AGE starts in Ramping, with `never_saturated = false`, `C` unknown, and `rate = max(INITIAL_RATE, RESTORE_FRACTION · headroom · saved capacity)`. It climbs ×(1+g) per tick to the old operating point, without the ×2 slow-start overshoot, and re-measures the capacity at the ramp's end.
- Without usable saved state, a law starts at INITIAL_RATE, Ramping, with `never_saturated = true`. An absent or unreadable saved-state file, or one for a link no longer configured, means a cold start.
- Baselines are never restored: the paths may have changed.

### 4.8 Shutdown

When a stop is requested, `fail_waiting(STOPPING)` runs on every link. Each queued waiter fails having taken nothing, and its caller treats the work as owed and still on disk, without retrying it. Bodies already in flight finish or are cut by the rest of the shutdown, and their tickets release the window as usual. The owner saves its state (§4.7). A lessee's row disappears at the owner's next step once its process is gone.

### 4.9 Status

Per link: `enabled`, `state` (`ramping`, `steady`, `backingOff`, or `leased`), `limit`, `maxRateBytesPerSec`, `rateBytesPerSec`, `capacityBytesPerSec`, `baseDelayMs`, `queueingDelayMs`, `inFlightBytes`, `windowBytes`, `drops`, `headroom`, `targetDelayMs`, `waiting`, `mode`. An owner adds `ownRateBytesPerSec` and `lessees[{pid, rateBytesPerSec, inFlightBytes, waiting, heldBack, probeMs}]`. Dormant links are kept but not listed.

---

## 5. Properties and why they hold

### 5.1 Safety

- **S1 Admission never exceeds the budget.** Over any interval `[t₀, t₁]` a process admits at most `burst + share_rate·(t₁ − t₀)` plus one oversize body's debt: tokens are earned only by refill, and every take subtracts the full size. `in_flight ≤ max(window, largest single body)`. Both rest on check-then-take being one step, which `acquire` and `try_acquire` guarantee.
- **S2 No body waits forever while others pass.** The head is displaced only by small bodies, in total by no more than its own size. A refill-bound head has an armed timer, and a window-bound head has bytes in flight whose ticket will pump.
- **S3 Deliverability (G5).** In the worst case a body is the last byte of a full window, and reaches the wire after `window/share_rate = STALL_TIMEOUT · WINDOW_SAFETY`. A rate cut shrinks the window for later admissions, and bodies already admitted drain at the link's real speed. When the link drains slower than the rate, the resulting timeout is exactly the signal that cuts the rate.
- **S4 Rate bounds.** After every tick, `min_rate ≤ rate ≤ max_rate`, `rate ≥ DECREASE_FLOOR × previous rate` unless `min_rate` lifts it, and `share_rate ≥ 1 B/s`.
- **S5 Growth only under demand (G4).** The rate grows only if some party was held back since the last step and bytes completed within RATE_WINDOW. An idle or trickling process holds its rate.
- **S6 Retries are paced.** Every attempt is admitted and reported, so the admitted volume is the volume sent.
- **S7 Grants fit the link.** After a split, grants add up to the law's rate, floors included.

### 5.2 Operating point and stability (single sender)

Model the bottleneck as a fluid queue draining at the available capacity `A` (link capacity minus foreign load).

- **Equilibrium is at the ceiling, not at the target.** With `C ≈ A`, the ceiling `h·C < A`, so arrivals are below service and the queue drains. `q → 0` gives `off → +1`, the controller asks for growth under demand, and the ceiling clips it. The steady state is `r* = h·C` with a near-zero queue. `T` is the alarm threshold that says a queue is building, and headroom is the margin that keeps it from forming. This differs from LEDBAT, whose equilibrium holds `T` of standing queue.
- **Recovery from overshoot.** When `A < r` the queue grows until `q > T`. In Steady each tick multiplies the rate by at least 0.75, so it falls below `A` within `⌈log_{0.75}(A/r)⌉` ticks. Once settled and then over target for two ticks, `C := min(C, achieved) ≤ A`, and the operating point re-forms below the new `A`. The queue is non-increasing from the first tick at which `r < A`, and strictly decreasing at rate `≥ (1 − h)·A` once `r ≤ h·A`.
- **Bounded ramp overshoot.** A ramp step happens only at `q ≤ T/2`, and the end requires `q > T` twice. The first ramp (×2) can overshoot by 4 to 8 times, the analogue of slow start. Later ramps (×1.25) overshoot by at most about 2 times. Steady inherits the ramp's queue, but `settled` stays false until it drains, so the self-built queue is not taken for a foreign share.
- **Estimation bias.** The estimate `rate/√step` is clamped to `[achieved, 2·achieved]`, so it cannot be read off a rate that no data met. Detection lag biases it high by up to `√step`, which headroom absorbs. A sender with one body in flight at a time can bias it low, which the next periodic ramp corrects.
- **Limit cycle.** Under sustained demand, Steady returns to Ramping every PROBE_UP_EVERY. The ramp climbs ×1.25 per tick from `h·C` until the queue is confirmed, re-measures `C`, and returns. The cost is a brief delay spike about once a minute, the price of discovering a faster link (G2).
- **Timeouts.** A timeout halves the rate, lowers `C` to `achieved`, holds for BACKOFF_HOLD, then ramps at ×1.25. An unanswered probe reads as a PROBE_TIMEOUT delay, which cuts through the ordinary Steady rule.

### 5.3 Behaviour in specific situations

| Situation | Behaviour |
|---|---|
| **Idle link** | No probes. `queueing` halves each tick, the rate holds, `C` is kept. Periodic ramps lift the ceiling, but nothing grows without demand. |
| **Burst after idle** | The bucket is full: up to `burst` bytes, and at least one body, go at once, then the refill pace applies, capped by the window. The first probe comes at most one TICK after bytes are in flight. A baseline measured earlier still holds, and can only fall or rise slowly (§4.4). |
| **Link gets faster** | Found by the next periodic ramp, at most about PROBE_UP_EVERY plus the ramp's length later. |
| **Link gets slower / foreign traffic appears** | The queue rises; the rate shrinks up to ×0.75 per tick, then `C := min(C, achieved)`. A loss-based foreign flow keeps the queue high, so tsync falls to `min_rate` and stays there: scavenger behaviour. |
| **Foreign traffic leaves** | Delay falls and the rate climbs back to the lowered ceiling. The ceiling itself lifts at the next periodic ramp. |
| **Stalled request** | Its bytes stay in flight; a full window waits for its ticket, not a timer. When the stall detector fires, the store's timeout count rises and the next step halves the rate. The retry is admitted afresh. |
| **Many small bodies** | Each costs its payload plus REQUEST_OVERHEAD in tokens. Small bodies overtake a queued chunk by at most the chunk's size. |
| **Mixed near and far stores** | Each store has its own baseline, and the least queued path is read. A store held down by health is not probed. If every store is held while bytes are in flight, `queueing` holds its value. |
| **Shutdown** | Waiters fail at once with STOPPING. The owner saves its state. |
| **Owner restarts** | Lessees miss renewals and go Local after MISSED_BEFORE_LOCAL. A Local process takes the governor lock when it frees and becomes owner; the others lease from it. The new owner's laws start from saved state. |

### 5.4 Multiple processes on one machine (G6)

- **One controller.** Exactly one law runs per link while an owner is reachable. Every other process admits at a grant.
- **Max-min fairness.** Water-filling gives max-min fairness over the stated caps. A party with a line gets an equal share of what the less demanding parties leave. A party moving bytes without a line gets 1.25 times its recent throughput. An idle party gets the floor, so its first body can go. The leftover is spread over every party, so a waking party can burst without waiting a tick.
- **Measurement and demand.** Lessee probes and completions feed the owner's law, so the owner measures a link it has no store on. `held_back` from any party enables growth, and one split consumes it.

### 5.5 Multiple links

Each link has its own law, budget, line, baselines and lessee table. Timeouts and probes are per store, so a cut on one link never touches another. One renewal carries every link. Two differently named links that in fact cross one bottleneck are two uncoordinated controllers, each yielding to the other's queue.

### 5.6 Fairness against other senders

- **Loss-based TCP** drives the queue to the buffer's depth. tsync reads that as a persistent queue and backs off to `min_rate`: deliberately a lower-than-best-effort sender.
- **Another tsync machine, or a LEDBAT flow.** Both see the same queue and both cut; each lowers `C` to its own `achieved`. There is no equal-split guarantee. The periodic ramps re-contest the link every minute. A latecomer may take a standing queue for its baseline; the bounded baseline rise (§4.4) keeps the incumbent from adopting that queue quickly as its own baseline.
- **The floor.** tsync never fully yields: against a saturating flow it still sends `min_rate`, so it always makes progress.

---

## 6. Failure, crash and resume

| Point of interruption | Effect |
|---|---|
| **Process crash while bodies wait** | The waiters disappear with the process; their work is owed by whatever queued it. |
| **Crash with bytes in flight** | The store may or may not have the body; puts are idempotent by the store contract. |
| **Lessee crashes** | Its row is dropped at the owner's next step (pid gone). |
| **Owner crashes** | Lessees go Local after MISSED_BEFORE_LOCAL renewals; one takes the governor lock and becomes owner, from saved state. |
| **Renewal times out once or twice** | The lessee keeps its last grant, which is only an admission rate. |
| **Owner of an older build** | An answer without per-link grants is a refusal; the process goes Local at once. |
| **Lessee of an older build** | Its flat report is read as the `"wan"` link and answered with a top-level rate too. |
| **Probe fails** (other than a timeout) | The sample is dropped. Store health is the retry ladder's concern. |
| **Probe times out** | Read as a PROBE_TIMEOUT delay. |
| **Saved state unreadable** | Ignored: the law starts cold. |
| **Configuration changed** | The first configuration in a process wins; settings change on restart. |

Counts are idempotent where it matters: tickets report once, `held_back` is spent by one split, completed and timeout counts are deltas cleared as they are read.

---

## 7. Parameters

| Parameter | Recommended | Bound / effect |
|---|---|---|
| `enabled` (config) | true | Off admits everything at once. |
| `headroom` `h` (config) | 0.8 | MUST be in (0, 1]. Steady rate as a fraction of measured capacity. |
| `target_delay` `T` (config) | 50 ms | MUST be ≥ 5 ms. Alarm threshold on queueing delay. |
| `min_rate` (config) | 64 KiB/s | MUST be > 0. Floor of the law's rate; per-party floors are `min(min_rate, total/n)`. |
| `max_rate` (config) | none | MUST be ≥ `min_rate`. Hard ceiling. |
| INITIAL_RATE | 256 KiB/s | Starting rate of a cold law. |
| TICK | 2 s | Control, renewal and probe period. |
| GAIN `g` | 0.25 | Step per tick ×[0.75, 1.25]; later ramp steps ×1.25. |
| First ramp step | ×2 | Only while the link has never been saturated. |
| Confirmation | 2 ticks over T | To end a ramp and to lower `C` in Steady. |
| EWMA weight | ½ per tick | Queue-signal smoothing. |
| DECREASE_FLOOR | 0.5 | MUST be in (0, 1). Largest cut in one tick; the timeout cut. |
| BASE_CELL × BASE_CELLS = BASE_WINDOW | 60 s × 10 = 600 s | Memory of the per-path minimum. |
| BASE_MAX_RISE | `T` per BASE_WINDOW | How fast an effective baseline may rise. |
| RATE_WINDOW | 10 s (1 s cells) | `achieved` averaging. |
| PROBE_UP_EVERY | 60 s | Periodic ceiling lift in Steady. |
| BACKOFF_HOLD | 10 s | Hold after a timeout before ramping. |
| PROBE_TIMEOUT | 10 s | Limit on a probe; an unanswered probe reads as this delay. |
| BURST_SECONDS | 2 s | Bucket depth in seconds of rate. |
| STALL_TIMEOUT | 60 s | The transport's stall detector; every remote driver's stall timeout MUST be ≥ it. |
| WINDOW_SAFETY | 0.5 | MUST be < 1. Fraction of the stall timeout the in-flight backlog may take to cross. |
| SMALL_BODY | 64 KiB | Largest body allowed to overtake the line. |
| REQUEST_OVERHEAD | 1 KiB | Bytes billed per attempt on top of its body. |
| Lessee cap factor | 1.25 × recent use | Room a non-waiting mover gets. |
| LEASE_TTL | 3·interval + PROBE_TIMEOUT | Silence before a lessee row is dropped. |
| MISSED_BEFORE_LOCAL | 3 | Unanswered renewals before a lessee goes Local. |
| RENEWAL_TIMEOUT | 1 s | Deadline of one renewal. |
| LOCAL_RETRY | 30 s | How often a Local process tries to own or lease. |
| STATE_SAVE_INTERVAL | 60 s | How often the owner saves law state. |
| STATE_MAX_AGE | 24 h | Saved state older than this is ignored. |
| RESTORE_FRACTION | 0.5 | Fraction of the saved operating point a restored law starts from. |

---

## 8. Alternatives and rationale

- **Throughput caps** (a fixed per-store rate). A fixed number is wrong on every link but one: two megabytes a second is all of a small pipe or half of a large one.
- **LEDBAT** (RFC 6817) is the model: delay above a minimum-filtered baseline, a fixed target, grow below and shrink above, cut on loss. The differences: a rate adjusted every tick, not a window per ACK (bodies are MiB over HTTP); an equilibrium at `h·C` with a near-empty queue; a capacity estimate replaced by each ramp, borrowed from BBR; periodic probing, because pure LEDBAT never learns that the link got faster; per-path baselines; a bounded baseline rise against base drift.
- **TCP Vegas** compares expected and actual throughput; its additive per-RTT steps are far too slow at a 2 s period.
- **BBR** shares the explicit bottleneck estimate, pacing below it, periodic probing up and a minimum-RTT baseline with expiry. It competes with loss-based flows instead of yielding to them; yielding is a goal here.
- **AIMD** does not scale over three orders of magnitude of link speed at a 2 s period. Multiplicative steps are scale-free; fairness on one machine comes from the owner's split, and between machines from each sender lowering `C` to its own share.
- **Kernel-level pacing** (`SO_MAX_PACING_RATE`, router queue management) still needs someone to choose the rate, paces per socket rather than per link, or is out of reach.
- **One law per process.** N independent laws on one link each see the others' queue as foreign traffic and all back off to the floor, and a new process starts cold. Hence one owner and leases.
- **Probe choice.** A metadata read of the domain cursor exists on every written store and costs almost nothing. It is sent only while bytes are in flight, because probes are billed.
- **Growth requires held-back demand and completing bytes**, and completions are credited over their duration: without that, an idle daemon's rate ran away to terabytes a second and a long body read as a burst.
- **Capacity bounded by 2× achieved**: a single-body-in-flight sender once read a link of a few MB/s as twenty.
- **Two ticks to end a ramp**: one probe queued behind one body reads as a phantom queue.
- **Per-attempt admission**: retries admitted once per request sent more bytes than the budget allowed on exactly the links that were already failing.
- **Floors inside the link rate**: floors of `min_rate` per party oversubscribed the link by `n·min_rate`.
- **Pure, time-handed modules.** The budget, law and split never read a clock, so they are checked at chosen instants on a fake clock.

---

## 9. Conformance

An implementation MUST exhibit:

- **Budget.** Full at birth (BURST_SECONDS of rate); an oversize body is admitted on a full bucket and its debt is paid before the next; the long-run rate holds; window = `STALL_TIMEOUT · WINDOW_SAFETY · rate`; a lone oversize body passes when nothing is in flight; a rate change keeps earned tokens and clips the depth; the rate floor is 1 B/s.
- **Gate.** FIFO order; a small body overtakes a chunk by at most the chunk's size; a head blocked by the window is woken by a completion; `try_acquire` takes atomically, and a refusal counts a drop; `fail_waiting` fails every waiter having taken nothing; a disabled link's tickets release nothing.
- **Law, driven against a simulated fluid link on a fake clock.** A doubling first ramp; steady within 40 s at headroom of the measured capacity with the queue drained; lowering to a competing share and recovering within a probe interval; a timeout halves the rate, holds 10 s, then ramps; no tick lowers the rate by more than DECREASE_FLOOR; a `maxRate` ceiling is reported `configured`; the `minRate` floor holds; no growth without being held back or without completions; base delay learnt, and a standing queue held for longer than BASE_WINDOW raises the effective baseline by at most BASE_MAX_RISE per window; a held-down near store does not cut; no samples while busy holds `queueing`.
- **Lease.** An even split among waiting parties; the floor for an idle party; 1.25× use for a mover; the leftover shared; grants summing to the total with floors included; a newcomer answered from an immediate re-split; a row dropped at once when its pid is gone and after LEASE_TTL of silence; `heldBack` spent by one split; old report and answer shapes read as specified.
- **Modes.** Two missed renewals keep a lessee Leased, the third makes it Local; a refusal makes it Local at once; a Local process takes the governor lock when it is free; the owner probes on behalf of a busy lessee; cuts are per link; one request renews every link.
- **Restart.** A law with fresh saved state starts at `RESTORE_FRACTION · headroom · capacity` with ×1.25 steps; stale or missing state starts cold.
- **Retries.** A retried upload attempt is admitted and reported again.

---

OCaml implementation notes: [ocaml/algorithms/uplink-governor.md](../ocaml/algorithms/uplink-governor.md).
