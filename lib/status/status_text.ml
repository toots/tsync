open Status_report
module Uplink = Tsync_store.Uplink

let size b =
  if b < 1024. then Printf.sprintf "%.0f B" b
  else (
    let rec go b = function
      | [u] -> Printf.sprintf "%.1f %s" b u
      | u :: rest ->
          if b < 1024. then Printf.sprintf "%.1f %s" b u
          else go (b /. 1024.) rest
      | [] -> assert false
    in
    go (b /. 1024.) ["KiB"; "MiB"; "GiB"; "TiB"])

let isize n = size (float_of_int n)
let rate b = size b ^ "/s"

let duration s =
  let s = int_of_float (Float.max 0. s) in
  if s < 3600 then Printf.sprintf "%dm %ds" (s / 60) (s mod 60)
  else if s < 86400 then Printf.sprintf "%dh %dm" (s / 3600) (s mod 3600 / 60)
  else Printf.sprintf "%dd %dh" (s / 86400) (s mod 86400 / 3600)

(* The first folder and as many trailing parts as fit in [width]. *)
let shorten ?(width = 60) path =
  if String.length path <= width then path
  else (
    match String.split_on_char '/' path with
      | first :: (_ :: _ as rest) ->
          let rec keep acc len = function
            | part :: more when len + String.length part + 1 <= width ->
                keep (part :: acc) (len + String.length part + 1) more
            | _ -> acc
          in
          let tail =
            match keep [] (String.length first + 2) (List.rev rest) with
              | [] -> [List.nth rest (List.length rest - 1)]
              | tail -> tail
          in
          String.concat "/" (first :: "…" :: tail)
      | _ -> path)

let plural n one many = Printf.sprintf "%d %s" n (if n = 1 then one else many)

let row b indent label value =
  Printf.bprintf b "%s%-16s %s\n" indent label value

let some_list l = List.filter_map Fun.id l

let settings b (s : settings) =
  row b "  " "settings"
    (String.concat ", "
       [
         ("versioning " ^ if s.versioning then "on" else "off");
         ("symlinks "
         ^
           match s.symlinks with
           | `Keep -> "keep"
           | `Follow -> "follow"
           | `Skip -> "skip");
         ("chunk " ^ isize s.chunk_size
         ^ if s.chunk_size_default then " (default)" else "");
         "cache chunk " ^ isize s.cache_chunk_size;
       ]);
  row b "  " "concurrency"
    (Printf.sprintf "%s, %s, %s"
       (plural s.max_uploads "upload" "uploads")
       (plural s.max_chunk_buffers "chunk buffer" "chunk buffers")
       (plural s.max_downloads "download" "downloads"));
  if s.read_only then row b "  " "read-only" "yes"

let cache b (c : cache) =
  row b "  " "cache"
    (String.concat ", "
       (some_list
          [
            Some (plural c.chunks "chunk" "chunks");
            Some
              (isize c.bytes
              ^ Option.fold ~none:""
                  ~some:(fun m -> " of " ^ isize m)
                  c.max_cache);
            (if c.pinned_bytes > 0 then Some (isize c.pinned_bytes ^ " pinned")
             else None);
          ]))

let sync b (d : domain_body) =
  let s = d.sync in
  if d.paused then row b "  " "PAUSED" "changes stay local until resumed";
  if d.main_offline then
    row b "  " "MAIN OFFLINE" "reads and publishing wait for it";
  Option.iter (row b "  " "SYNC HELD") s.hold;
  if s.unapplied_entries > 0 then
    row b "  " "unapplied"
      (plural s.unapplied_entries "peer entry" "peer entries"
      ^ Option.fold ~none:"" ~some:(fun r -> " (" ^ r ^ ")") s.unapplied_reason
      );
  if s.parked_metadata > 0 then
    row b "  " "parked"
      (plural s.parked_metadata "metadata change" "metadata changes")

let queues b (q : queues) =
  if q.pending_files > 0 then
    row b "  " "uploads"
      (plural q.pending_files "file" "files"
      ^ " pending, " ^ isize q.bytes_owed ^ " owed"
      ^
        match q.in_flight with
        | [] -> ""
        | l -> ", sending " ^ String.concat ", " l);
  if q.pending_metadata > 0 then
    row b "  " "metadata"
      (plural q.pending_metadata "change" "changes" ^ " pending")

let wal b (w : wal) =
  if w.stuck > 0 then
    row b "  " "WAL STUCK"
      (plural w.stuck "record" "records"
      ^ Option.fold ~none:"" ~some:(fun e -> ": " ^ e) w.last_error)

let traffic b indent (t : traffic) =
  row b indent "traffic"
    (Printf.sprintf "up %s (%s), down %s (%s)" (isize t.up_bytes)
       (rate t.up_rate) (isize t.down_bytes) (rate t.down_rate))

let frontend b (f : frontend) =
  Printf.bprintf b "  Frontend %-10s %s%s\n" f.kind
    (String.concat "  "
       (some_list
          [
            Option.map (Printf.sprintf "pid %d") f.pid;
            f.mount;
            Option.map (Printf.sprintf "port %d") f.port;
            (if f.shared then Some "shared" else None);
            (if f.read_only = Some true then Some "read-only" else None);
            (if f.shares = Some true then Some "share links" else None);
          ]))
    (if f.unanswered then "  NOT ANSWERING" else "");
  (match f.open_handles with
    | Some n when n > 0 -> row b "    " "open" (plural n "handle" "handles")
    | _ -> ());
  match (f.bytes_read, f.bytes_written) with
    | Some r, Some w when r > 0 || w > 0 ->
        row b "    " "io"
          (Printf.sprintf "read %s, written %s" (isize r) (isize w))
    | _ -> ()

let backend b (be : backend) =
  Printf.bprintf b "  Backend %s (%s, %s)%s\n" be.name be.kind be.role
    (String.concat ""
       (List.filter_map
          (fun (k, v) ->
            if v = "***" then None else Some (Printf.sprintf "  %s %s" k v))
          be.config));
  Option.iter (row b "    " "link") be.link;
  (match (be.health, be.reach) with
    | Down d, _ ->
        row b "    " "HELD DOWN"
          (Printf.sprintf "for %s after %s (%s)" (duration d.held_for)
             (plural d.failures "failure" "failures")
             d.reason)
    | Up, Reachable r ->
        row b "    " "reachable" (Printf.sprintf "yes (%.0f ms)" r.latency_ms)
    | Up, Unreachable e -> row b "    " "UNREACHABLE" e);
  (match be.journal with
    | Counting -> row b "    " "journal" "counting…"
    | Unreadable e -> row b "    " "journal" ("unreadable: " ^ e)
    | Entries e ->
        row b "    " "journal"
          (Printf.sprintf "%s, %d to apply"
             (plural e.entries "entry" "entries")
             e.behind));
  (match be.corrupted with
    | Not_checked why ->
        row b "    " "corrupted"
          ("not checked" ^ if why = "" then "" else " — " ^ why)
    | Checked { chunks = 0; _ } -> ()
    | Checked c ->
        row b "    " "CORRUPTED"
          (plural c.chunks "chunk" "chunks"
          ^ if c.truncated then " or more" else ""));
  Option.iter
    (fun (d : disk) ->
      row b "    " "disk"
        (Printf.sprintf "%s free of %s" (isize d.free_bytes)
           (isize d.total_bytes)))
    be.disk;
  Option.iter
    (fun (c : copies) ->
      if c.owed > 0 then (
        row b "    " "copies"
          (Printf.sprintf "%s owed%s, %.1f/s"
             (plural c.owed "object" "objects")
             (if c.parked > 0 then Printf.sprintf " (%d parked)" c.parked
              else "")
             c.rate);
        Option.iter
          (fun (j : copy_job) ->
            row b "    " "sending"
              (Printf.sprintf "%s%s%s, %s%s"
                 (shorten (Option.value ~default:j.job j.path))
                 (Option.fold ~none:""
                    ~some:(fun s -> " (" ^ isize s ^ ")")
                    j.size)
                 (if j.chunks > 0 then
                    Printf.sprintf ": chunk %d of %d" j.checked j.chunks
                  else "")
                 (if j.sent = 0 then "checking what the copy holds"
                  else isize j.sent ^ " sent")
                 (Option.fold ~none:""
                    ~some:(fun e -> ", done in at most " ^ duration e)
                    j.eta)))
          c.current))
    be.copies;
  Option.iter (traffic b "    ") be.traffic

let domain b = function
  | Unanswered name -> Printf.bprintf b "\nDomain %s  NOT ANSWERING\n" name
  | Answered d ->
      Printf.bprintf b "\nDomain %s\n" d.name;
      settings b d.settings;
      cache b d.cache;
      sync b d;
      queues b d.queues;
      wal b d.wal;
      List.iter (frontend b) d.frontends;
      List.iter (backend b) d.backends

let memory (u : usage) =
  Printf.sprintf "private %s (heap %s%s), mapped files %s"
    (isize u.private_bytes) (isize u.heap_bytes)
    (Option.fold ~none:""
       ~some:(fun a -> ", anonymous " ^ isize a)
       u.anonymous_bytes)
    (Option.fold ~none:"?" ~some:isize u.file_backed_bytes)

(* A lessee's or Local process's own view: the rate its budget admits at. *)
let own_uplink b (l : Uplink.link_status) =
  match l.mode with
    | `Owner -> ()
    | (`Leased | `Local) as mode ->
        row b "    " ("uplink " ^ l.name)
          (Printf.sprintf "%s %s, %s in flight%s" (rate l.rate)
             (if mode = `Leased then "leased" else "run locally")
             (isize l.in_flight)
             (if l.waiting > 0 then Printf.sprintf ", %d waiting" l.waiting
              else ""))

let listener b (l : listener) =
  row b "    " "listener"
    (String.concat ", "
       (some_list
          [
            Option.map (Printf.sprintf "port %d") l.port;
            (if l.tls then Some "TLS" else None);
            Some
              (Printf.sprintf "%d in flight (%d data)" l.in_flight
                 l.data_in_flight);
            Some
              (Printf.sprintf "read %s, written %s" (isize l.bytes_read)
                 (isize l.bytes_written));
          ]));
  match List.filter (fun (_, n) -> n > 0) l.requests with
    | [] -> ()
    | counted ->
        row b "    " "requests"
          (String.concat ", "
             (List.map (fun (k, n) -> Printf.sprintf "%s %d" k n) counted))

let process b (p : process) =
  Printf.bprintf b "  %-12s %s\n" p.role
    (String.concat "  "
       (some_list
          [
            Some
              (Option.fold ~none:"pid -" ~some:(Printf.sprintf "pid %d") p.pid);
            Option.map
              (fun (s : self) -> "up " ^ duration s.server.uptime)
              p.self;
            Option.map
              (fun (s : self) ->
                Printf.sprintf "%.1f%% cpu" s.usage.cpu_percent)
              p.self;
            (if p.serves = [] then None else Some (String.concat ", " p.serves));
          ]));
  match (p.self, p.error) with
    | _, Some e -> row b "    " "NOT ANSWERING" e
    | Some s, None ->
        row b "    " "memory" (memory s.usage);
        Option.iter (traffic b "    ") s.traffic;
        Option.iter (listener b) s.listener;
        List.iter (own_uplink b) s.uplinks
    | None, None -> ()

let state_name = function
  | `Ramping -> "ramping"
  | `Steady -> "steady"
  | `Backing_off -> "backing off"
  | `Leased -> "leased"

let limit_name : Uplink.limit -> string = function
  | Configured -> "configured"
  | Measured -> "measured"
  | Estimating -> "estimating"

let uplinks b (m : machine) =
  let role pid =
    match List.find_opt (fun (p : process) -> p.pid = Some pid) m.processes with
      | Some p -> ( p.role ^ match p.serves with [d] -> " " ^ d | _ -> "")
      | None -> Printf.sprintf "pid %d" pid
  in
  if m.uplinks <> [] then (
    Printf.bprintf b "\nUplinks\n";
    List.iter
      (fun (l : Uplink.link_status) ->
        Printf.bprintf b "  %-10s %s, %s (%s)\n" l.name (state_name l.state)
          (rate l.rate) (limit_name l.limit);
        row b "    " "measured"
          (Printf.sprintf
             "sent %s, capacity %s, queueing %.0f ms over a baseline of %s"
             (rate l.achieved)
             (Option.fold ~none:"not measured yet" ~some:rate l.capacity)
             l.queueing_delay_ms
             (Option.fold ~none:"?" ~some:(Printf.sprintf "%.0f ms")
                l.base_delay_ms));
        if l.in_flight > 0 || l.waiting > 0 then
          row b "    " "in flight"
            (Printf.sprintf "%s, %d waiting" (isize l.in_flight) l.waiting);
        if l.lessees <> [] then
          row b "    " "shares"
            (String.concat ", "
               (List.map
                  (fun (x : Uplink.lessee_status) ->
                    Printf.sprintf "%s %s%s" (role x.pid) (rate x.rate)
                      (if x.waiting > 0 then
                         Printf.sprintf " (%d waiting)" x.waiting
                       else ""))
                  l.lessees)))
      m.uplinks)

let jobs b (m : machine) =
  if m.jobs <> [] then (
    Printf.bprintf b "\nJobs\n";
    List.iter
      (fun (j : job) ->
        Printf.bprintf b "  %s%s (pid %d)%s\n" j.kind
          (Option.fold ~none:"" ~some:(fun d -> " " ^ d) j.domain)
          j.pid
          (match (j.state, j.progress) with
            | `Failed, _ ->
                ": FAILED"
                ^ Option.fold ~none:"" ~some:(fun e -> " " ^ e) j.error
            | `Done, _ -> ": done"
            | `Running, Some p ->
                Printf.sprintf ": %d of %d%s" p.finished p.total
                  (Option.fold ~none:""
                     ~some:(fun e -> ", " ^ duration e ^ " left")
                     p.eta)
            | `Running, None -> ""))
      m.jobs)

let shown_warnings = 10

let warnings b ~now (m : machine) =
  if m.warnings <> [] then (
    Printf.bprintf b "\nWarnings (newest first)\n";
    List.iteri
      (fun i (w : warning) ->
        if i < shown_warnings then
          Printf.bprintf b "  %s ago %s %s%s\n"
            (duration (now -. w.last))
            (match w.level with
              | Err -> "ERROR"
              | Warn -> "WARN"
              | Info -> "INFO"
              | Debug -> "DEBUG")
            w.message
            (if w.count > 1 then Printf.sprintf " (×%d)" w.count else ""))
      m.warnings;
    let n = List.length m.warnings in
    if n > shown_warnings then
      Printf.bprintf b "  … and %d more\n" (n - shown_warnings))

let header b (m : machine) =
  let supervisor =
    List.find_map
      (fun (p : process) -> if p.role = "supervisor" then p.self else None)
      m.processes
  in
  Printf.bprintf b "tsync on %s — %s, %s%s%s\n" m.host
    (plural (List.length m.domains) "domain" "domains")
    (plural (List.length m.processes) "process" "processes")
    (Option.fold ~none:""
       ~some:(fun (s : self) -> ", up " ^ duration s.server.uptime)
       supervisor)
    (Option.fold ~none:""
       ~some:(Printf.sprintf ", load %.1f")
       (Option.bind supervisor (fun (s : self) -> s.server.load_avg)))

let render ~now m =
  let b = Buffer.create 4096 in
  header b m;
  List.iter (domain b) m.domains;
  if m.processes <> [] then (
    Printf.bprintf b "\nProcesses\n";
    List.iter (process b) m.processes);
  uplinks b m;
  jobs b m;
  warnings b ~now m;
  Buffer.contents b
