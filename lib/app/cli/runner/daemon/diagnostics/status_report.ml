(* One machine's report, assembled from what its processes say about themselves.

   {!Diagnostics} is what a single process can answer: its own counters
   ({!Diagnostics.self_json}) and the domains it holds
   ({!Diagnostics.Make.domain_json}). This is the other half — asking the
   processes beside it and folding the answers into the one report a reader
   sees. A collector fans out; a frontend answers about itself and never asks
   anyone, or a collector asking it would square the fan-out. *)

open Lwt.Syntax

let mem j name = try Yojson.Safe.Util.member name j with _ -> `Null

(* Answer about yourself, not about the domain: the frontend's own figures
   without the cache walk, the WAL read and a probe of every backend. Travels in
   the same comma-separated [arg] as [totals]/[exact]/[reload]. *)
let frontend_only = "frontend"

(** What one process answered when asked about one domain.

    [reply] is kept whole rather than filtered here: which fields a report needs
    is the assembler's question, and an allowlist at the point of collection is
    the reader deciding what the writer may say. *)
type answer = {
  domain : string;
  frontend : string;  (** as the caller expected it there; [""] when unknown *)
  socket_path : string;
  reply : Yojson.Safe.t;
}

(* Never raises: a socket that does not answer is an answer saying so. A report
   whose job is to show what is wrong must not go missing when something is. *)
let ask ?timeout ?arg ~frontend ~domain ~socket_path () =
  let request =
    Yojson.Safe.to_string
      (`Assoc
         ([("action", `String "stats"); ("domain", `String domain)]
         @ match arg with None -> [] | Some a -> [("arg", `String a)]))
  in
  let+ reply =
    Lwt.catch
      (fun () ->
        let+ resp = Ipc_lwt.send_lwt ?timeout ~socket_path request in
        match Yojson.Safe.from_string resp with
          | json -> json
          | exception _ -> `Assoc [("error", `String "unreadable answer")])
      (fun exn ->
        Lwt.return
          (`Assoc
             [
               ( "error",
                 `String
                   (match exn with
                     | exn when Io_lwt.Clock.is_timeout exn -> "timed out"
                     | exn -> Printexc.to_string exn) );
             ]))
  in
  { domain; frontend; socket_path; reply }

(* A domain's frontends are separate processes and {!Metrics} counts per process,
   so a mount's traffic is invisible to whoever asked and reporting only the
   asker's own would call a busy machine idle. Its transfer figures and process
   cost come across attributed to it. *)
let carried_keys =
  [
    ("pid", ["server"]);
    ("uptimeSeconds", ["server"]);
    ("cpuSeconds", ["process"]);
    ("rssBytes", ["process"]);
    ("traffic", []);
  ]

(** The entry this answer contributes to its domain's [frontends]: what only
    that frontend knows, plus enough of its process to place it. *)
let frontend_entry a =
  let unreachable detail =
    `Assoc
      ((match a.frontend with "" -> [] | t -> [("type", `String t)])
      @ [
          ("reachable", `Bool false);
          ("socketPath", `String a.socket_path);
          ("error", `String detail);
        ])
  in
  match mem a.reply "error" with
    | `String detail -> unreachable detail
    | _ -> (
        let carried =
          List.filter_map
            (fun (key, path) ->
              let from = List.fold_left mem a.reply path in
              match mem from key with `Null -> None | v -> Some (key, v))
            carried_keys
        in
        (* The domain it was asked about, not whichever it listed first: a
           daemon serving several answers about one of them. *)
        let for_domain =
          match mem a.reply "domains" with
            | `List ds -> (
                match
                  List.find_opt (fun d -> mem d "name" = `String a.domain) ds
                with
                  | Some d -> Some d
                  | None -> ( match ds with d :: _ -> Some d | [] -> None))
            | _ -> None
        in
        match Option.map (fun d -> mem d "frontends") for_domain with
          | Some (`List (`Assoc fields :: _)) -> `Assoc (fields @ carried)
          | _ -> unreachable "daemon reported no frontend")

let assoc = function `Assoc fields -> fields | _ -> []
let list = function `List l -> l | _ -> []
let str ?(default = "") j = match j with `String s -> s | _ -> default
let num j = match j with `Int n -> float_of_int n | `Float f -> f | _ -> 0.
let int_of j = int_of_float (num j)
let bool_of j = match j with `Bool b -> b | _ -> false
let non_null j = j <> `Null

(* A process as one flat entry, its counters beside its identity. [hostname] is
   dropped: it belongs to the machine, and every process here is on it. *)
let process_of reply =
  `Assoc
    (List.remove_assoc "hostname" (assoc (mem reply "server"))
    @ assoc (mem reply "process")
    @ List.filter_map
        (fun k -> match mem reply k with `Null -> None | v -> Some (k, v))
        ["traffic"; "pools"; "lwt"; "backend"])

(* A domain runs at most one frontend of each kind -- the launcher groups its
   bindings by frontend name -- so within a domain the kind is the identity. One
   that never answered may not have said what kind it is, and falls back to the
   socket that stayed silent. *)
let frontend_id f =
  match mem f "type" with
    | `String t -> "type:" ^ t
    | _ -> "socket:" ^ str (mem f "socketPath")

(* A frontend describes itself, and whoever asked it adds what it cannot see of
   its own process. Both descriptions are the one entry. *)
let merge_by id items =
  List.fold_left
    (fun kept item ->
      let key = id item in
      if List.exists (fun k -> id k = key) kept then
        List.map
          (fun k ->
            if id k <> key then k
            else
              `Assoc
                (assoc k
                @ List.filter
                    (fun (f, _) -> not (List.mem_assoc f (assoc k)))
                    (assoc item)))
          kept
      else kept @ [item])
    [] items

(* In place where the key is already there, appended where it is not, so a body
   this rewrites keeps the order it was built in. *)
let replace key value fields =
  if List.mem_assoc key fields then
    List.map (fun (k, v) -> if k = key then (k, value) else (k, v)) fields
  else fields @ [(key, value)]

let dedup id items =
  List.rev
    (fst
       (List.fold_left
          (fun (kept, seen) item ->
            let k = id item in
            if List.mem k seen then (kept, seen) else (item :: kept, k :: seen))
          ([], []) items))

(* The same failure is logged by everyone who saw it, and a retry ladder logs it
   once per attempt: without this a report is one message repeated a hundred
   times, with whatever else went wrong that day buried under it. *)
let warnings_of sources =
  let bump acc (frontend, pid, entry) =
    let key = (str (mem entry "level"), str (mem entry "message")) in
    let t = num (mem entry "t") in
    match List.assoc_opt key acc with
      | None -> acc @ [(key, (t, t, [(frontend, pid, 1)]))]
      | Some (first, last, from) ->
          let from =
            match
              List.assoc_opt (frontend, pid)
                (List.map (fun (f, p, n) -> ((f, p), n)) from)
            with
              | None -> from @ [(frontend, pid, 1)]
              | Some _ ->
                  List.map
                    (fun (f, p, n) ->
                      if (f, p) = (frontend, pid) then (f, p, n + 1)
                      else (f, p, n))
                    from
          in
          List.map
            (fun (k, v) ->
              if k = key then (k, (Float.min first t, Float.max last t, from))
              else (k, v))
            acc
  in
  List.fold_left bump [] sources
  |> List.map (fun ((level, message), (first, last, from)) ->
      `Assoc
        [
          ("level", `String level);
          ("message", `String message);
          ("count", `Int (List.fold_left (fun n (_, _, c) -> n + c) 0 from));
          ("firstAt", `Float first);
          ("lastAt", `Float last);
          ( "sources",
            `List
              (List.map
                 (fun (frontend, pid, n) ->
                   `Assoc
                     [
                       ("frontend", `String frontend);
                       ("pid", pid);
                       ("count", `Int n);
                     ])
                 from) );
        ])
  |> List.sort (fun a b ->
      compare (num (mem b "lastAt")) (num (mem a "lastAt")))

(* Every answer folded into the one report a reader sees.

   [local] is the collector's own {!Diagnostics.self_json}, [domains] the domain
   bodies it computed itself. A collector that computed none — [tsync status]
   falling back to asking each frontend directly — passes neither and the bodies
   come from the answers, which is why there is one fold and not two. *)
let of_answers ?(local = []) ?(domains = []) answers =
  let local = `Assoc local in
  let replies =
    (if local = `Assoc [] then [] else [local])
    @ List.map (fun a -> a.reply) answers
  in
  let answered = List.filter (fun a -> mem a.reply "error" = `Null) answers in
  let host =
    match
      List.find_opt
        (fun r -> non_null (mem (mem r "server") "hostname"))
        replies
    with
      | Some r -> str (mem (mem r "server") "hostname")
      | None -> ""
  in
  (* A body the collector computed wins over one an answer carried: the
     collector is the process that owns the domain. *)
  let bodies =
    domains
    @ List.filter
        (fun d ->
          not (List.exists (fun own -> mem own "name" = mem d "name") domains))
        (dedup
           (fun d -> str (mem d "name"))
           (List.concat_map (fun a -> list (mem a.reply "domains")) answered))
  in
  let domains =
    List.map
      (fun body ->
        let name = mem body "name" in
        let gathered =
          List.filter_map
            (fun a ->
              if `String a.domain = name then Some (frontend_entry a) else None)
            answers
        in
        `Assoc
          (replace "frontends"
             (`List
                (merge_by frontend_id (list (mem body "frontends") @ gathered)))
             (assoc body)))
      bodies
  in
  (* One row per process, whichever domain it answered about, with [serves]
     widened to every domain it answered for. *)
  let processes =
    let by_pid =
      List.filter (fun r -> non_null (mem (mem r "server") "pid")) replies
    in
    dedup (fun r -> Yojson.Safe.to_string (mem (mem r "server") "pid")) by_pid
    |> List.map (fun r ->
        let pid = mem (mem r "server") "pid" in
        let serves =
          dedup
            (fun d -> str d)
            (List.concat_map
               (fun other ->
                 if mem (mem other "server") "pid" = pid then
                   list (mem (mem other "server") "serves")
                 else [])
               replies)
        in
        match process_of r with
          | `Assoc fields -> `Assoc (replace "serves" (`List serves) fields)
          | j -> j)
  in
  (* Deduplicated by pid: where one process answers for several domains each
     answer carries that process's whole job table, and concatenating alone
     would list one import once per domain it is not running against. Absent is
     not equal to absent — two jobs naming no pid are two jobs. *)
  let jobs =
    List.concat_map (fun r -> list (mem r "jobs")) replies
    |> List.fold_left
         (fun kept j ->
           if
             non_null (mem j "pid")
             && List.exists (fun k -> mem k "pid" = mem j "pid") kept
           then kept
           else kept @ [j])
         []
  in
  let warnings =
    warnings_of
      (List.concat_map
         (fun r ->
           let server = mem r "server" in
           List.map
             (fun e ->
               (str ~default:"?" (mem server "frontend"), mem server "pid", e))
             (list (mem r "recentErrors")))
         replies)
  in
  `Assoc
    [
      ("host", `String host);
      ("domains", `List domains);
      ("processes", `List processes);
      ("jobs", `List jobs);
      ("warnings", `List warnings);
    ]

let bytes_or_unlimited j =
  match j with `Null -> "unlimited" | j -> Metrics.human_bytes (int_of j)

(* Unset is not absent: the effective value is what the primary backend
   recommends, else the built-in default. *)
let bytes_or_default j =
  match j with
    | `Null ->
        Printf.sprintf "%s (default)"
          (Metrics.human_bytes Conf.default_chunk_size)
    | j -> Metrics.human_bytes (int_of j)

(* A file deep in a tree is mostly path, and the row it sits on has figures to
   its right: the first folder and the name say which file, which is what a
   reader is looking for. *)
let elide path =
  if String.length path <= 48 then path
  else (
    let base = Filename.basename path in
    match String.index_opt path '/' with
      | Some i when i + 1 < String.length path - String.length base ->
          String.sub path 0 i ^ "/…/" ^ base
      | _ -> "…/" ^ base)

(* The one spelling of a traffic row. The process, a frontend, a store and a job
   each report the same four figures, and four copies of the format is how two of
   them come to disagree about what "up" means. *)
let traffic_row t =
  Printf.sprintf "up %s (%s/s), down %s (%s/s)"
    (Metrics.human_bytes (int_of (mem t "bytesUploaded")))
    (Metrics.human_bytes (int_of (mem t "uploadBytesPerSec")))
    (Metrics.human_bytes (int_of (mem t "bytesDownloaded")))
    (Metrics.human_bytes (int_of (mem t "downloadBytesPerSec")))

let moved t =
  int_of (mem t "bytesUploaded") > 0 || int_of (mem t "bytesDownloaded") > 0

let duration s =
  let s = int_of_float s in
  let d = s / 86400 and h = s mod 86400 / 3600 in
  let m = s mod 3600 / 60 in
  if d > 0 then Printf.sprintf "%dd %dh" d h
  else if h > 0 then Printf.sprintf "%dh %dm" h m
  else Printf.sprintf "%dm %ds" m (s mod 60)

let plural n word =
  Printf.sprintf "%d %s%s" n word
    (if n = 1 then ""
     else if String.ends_with ~suffix:"s" word then "es"
     else "s")

(* Distinct messages, not lines: the ×N beside each already says how many there
   were, and the point of the section is the ones a reader has not seen. *)
let warnings_shown = 10

let slots_row pools =
  String.concat ", "
    (List.map
       (fun p ->
         Printf.sprintf "%s %d/%d%s"
           (str (mem p "name"))
           (int_of (mem p "inFlight"))
           (int_of (mem p "max"))
           (match int_of (mem p "waiting") with
             | 0 -> ""
             | w -> Printf.sprintf " (%d waiting)" w))
       pools)

(* One renderer for every consumer, reading the JSON rather than the records, so
   a browser, [curl] and [tsync status] cannot disagree.

   Domains lead, because that is what a reader came for; the processes serving
   them are a table at the end. The idiom throughout is silent-when-clean: a row
   appearing at all is the signal, and a report of a healthy machine is short
   enough that an unhealthy one stands out. *)
let text json =
  let b = Buffer.create 4096 in
  (* Right-trimmed: rows are laid out with %-padding, and a row whose last
     column is empty would otherwise end in the padding. *)
  let line indent fmt =
    Printf.ksprintf
      (fun s ->
        let rec last i = if i > 0 && s.[i - 1] = ' ' then last (i - 1) else i in
        let s = String.sub s 0 (last (String.length s)) in
        Buffer.add_string b
          (if s = "" then "\n" else String.make indent ' ' ^ s ^ "\n"))
      fmt
  in
  let row indent label value = line indent "%-16s %s" label value in
  let domains = list (mem json "domains") in
  let processes = list (mem json "processes") in
  let host = str (mem json "host") in
  let uptime =
    List.fold_left
      (fun acc p -> Float.max acc (num (mem p "uptimeSeconds")))
      0. processes
  in
  line 0 "tsync%s — %s, %s%s"
    (if host = "" then "" else " on " ^ host)
    (plural (List.length domains) "domain")
    (plural (List.length processes) "process")
    (if uptime > 0. then ", up " ^ duration uptime else "");

  (* A frontend's own state: what only the process serving the domain knows.

     Every row is named here rather than taken from the answer's keys, which are
     wire names: a frontend adds a row by adding one below, and a key nobody has
     named stays in the JSON and out of the text. *)
  let frontend_block f =
    let shared = bool_of (mem f "shared") in
    let locator =
      match (mem f "mountPoint", shared) with
        | `String p, _ -> p
        | _, true -> "shared listener"
        | _ -> ""
    in
    line 2 "Frontend %s"
      (String.concat "  "
         (Printf.sprintf "%-11s"
            (str
               ~default:
                 (if bool_of (mem f "reachable") then "(unknown)"
                  else "(none answering)")
               (mem f "type"))
         :: List.filter
              (fun p -> p <> "")
              [
                (match mem f "pid" with
                  | `Null -> ""
                  | pid -> Printf.sprintf "pid %d" (int_of pid));
                locator;
              ]));
    if not (bool_of (mem f "reachable")) then
      row 4 "NOT ANSWERING"
        (Printf.sprintf "%s%s"
           (match mem f "socketPath" with `String p -> p ^ ": " | _ -> "")
           (str ~default:"no answer" (mem f "error")))
    else begin
      (match mem f "traffic" with
        | t when moved t -> row 4 "traffic" (traffic_row t)
        | _ -> ());
      (match (int_of (mem f "bytesRead"), int_of (mem f "bytesWritten")) with
        | 0, 0 -> ()
        | r, w ->
            row 4 "served"
              (Printf.sprintf "%s read (%s/s), %s written (%s/s)"
                 (Metrics.human_bytes r)
                 (Metrics.human_bytes (int_of (mem f "bytesReadPerSec")))
                 (Metrics.human_bytes w)
                 (Metrics.human_bytes (int_of (mem f "bytesWrittenPerSec")))));
      (match (int_of (mem f "openHandles"), int_of (mem f "filesOpened")) with
        | 0, 0 -> ()
        | open_, since ->
            row 4 "handles"
              (Printf.sprintf "%d open, %d since start" open_ since));
      (* Usual cause of a mount gone quiet while its backends answer fine, so it
         is loud when held and absent when not. *)
      if bool_of (mem f "metaLocked") then
        row 4 "metadata lock"
          (if bool_of (mem f "metaWaiting") then "HELD, callers waiting"
           else "held");
      let queued =
        List.filter_map
          (fun (key, word) ->
            match int_of (mem f key) with
              | 0 -> None
              | n -> Some (Printf.sprintf "%d %s" n word))
          [
            ("pendingUploads", "uploads");
            ("pendingDownloads", "downloads");
            ("stagedFiles", "staged");
          ]
      in
      if queued <> [] then row 4 "in flight" (String.concat ", " queued);
      (match
         (int_of (mem f "uploadsCompleted"), int_of (mem f "downloadsCompleted"))
       with
        | 0, 0 -> ()
        | up, down ->
            row 4 "completed" (Printf.sprintf "%d up, %d down" up down));
      (match int_of (mem f "handlerFailures") with
        | 0 -> ()
        | n -> row 4 "FAILED REQUESTS" (string_of_int n));
      List.iter
        (fun e ->
          row 4 "downloading"
            (Printf.sprintf "%s (%s of %s, %s)"
               (str (mem e "name"))
               (Metrics.human_bytes (int_of (mem e "bytes")))
               (Metrics.human_bytes (int_of (mem e "size")))
               (duration (num (mem e "seconds")))))
        (list (mem f "downloading"));
      (* What this process sweeps without being asked, and on what trigger. Read
         off the running frontend rather than the source, so one serving a
         different set of sweeps says so instead of looking like every other. *)
        (match list (mem f "maintenance") with
        | [] -> ()
        | tasks -> row 4 "maintenance" (String.concat "; " (List.map str tasks)));
      (* This listener's stance on the domain, not the domain's own. *)
      if bool_of (mem f "readOnly") then
        row 4 "read-only" "yes, for proxy clients";
      match mem f "shares" with
        | `Bool b -> row 4 "public shares" (if b then "served" else "off")
        | _ -> ()
    end
  in

  let backend_block m =
    (* So "which bucket is this?" has an answer without a row of its own. The
       masked values are the ones the producer already decided say nothing. *)
    let identifying =
      List.find_opt
        (fun (_, v) -> str v <> Field_spec.masked && str v <> "")
        (assoc (mem m "config"))
    in
    line 2 "Backend %s (%s, %s)%s"
      (str (mem m "name"))
      (str (mem m "type"))
      (str (mem m "role"))
      (match identifying with
        | Some (k, v) -> Printf.sprintf "  %s %s" k (str v)
        | None -> "");
    if bool_of (mem m "reachable") then
      row 4 "reachable"
        (Printf.sprintf "yes (%.0f ms)" (num (mem m "latencyMs")))
    else row 4 "UNREACHABLE" (str ~default:"no answer" (mem m "error"));
    let j = mem m "journal" in
    (match mem j "error" with
      | `String e -> row 4 "journal" ("error: " ^ e)
      | _ ->
          row 4 "journal"
            (Printf.sprintf "%d entries%s, %d to apply"
               (int_of (mem j "entries"))
               (if bool_of (mem j "truncated") then "+" else "")
               (int_of (mem j "behind"))));
    (* Silent on a store that is checked and clean, which is every store almost
       always. Not silent when nothing is checking, because that zero means
       something else. *)
    (let c = mem m "corrupted" in
     match (mem c "error", mem c "checked", int_of (mem c "chunks")) with
       | `String e, _, _ -> row 4 "corrupted" ("error: " ^ e)
       | _, `Bool false, _ ->
           row 4 "corrupted" "not checked — no verifier for this store"
       | _, _, 0 -> ()
       | _, _, n ->
           row 4 "corrupted"
             (Printf.sprintf "%d chunk%s%s — run tsync data-integrity --repair"
                n
                (if n = 1 then "" else "s")
                (if bool_of (mem c "truncated") then "+" else "")));
    (* A store with no link prints no row: a filesystem's zeros would read as an
       idle store rather than one that never had traffic. *)
    (match mem m "traffic" with
      | `Null -> ()
      | t -> row 4 "traffic" (traffic_row t));
    (match mem m "deferred" with
      | `Null -> ()
      | bf ->
          row 4 "behind"
            (Printf.sprintf "%d queued, %d in flight%s"
               (int_of (mem bf "queued"))
               (int_of (mem bf "inFlight"))
               (if bool_of (mem bf "degraded") then
                  " — DEGRADED, run tsync mirror"
                else "")));
    (* One syscall, so unlike the counts below this is on every request. *)
    (match mem m "disk" with
      | `Null -> ()
      | d ->
          let avail = int_of (mem d "availableBytes")
          and total = int_of (mem d "totalBytes") in
          row 4 "disk"
            (Printf.sprintf "%s free of %s (%d%% used)"
               (Metrics.human_bytes avail)
               (Metrics.human_bytes total)
               (if total > 0 then 100 * (total - avail) / total else 0)));
    match mem m "totals" with
      | `Null -> ()
      | t -> (
          (* Neither "could not look" nor "not counted yet" may read as "holds
             nothing". *)
            match (mem t "error", mem t "counting") with
            | `String e, _ -> row 4 "holds" ("could not count: " ^ e)
            | _, `Bool true -> row 4 "holds" "counting in the background"
            | _ ->
                (* The "~" keeps a sampled figure from reading as a counted one;
                   how it was sampled is in the JSON. *)
                let approx =
                  if mem t "chunksFromShards" = `Null then "" else "~"
                in
                row 4 "holds"
                  (Printf.sprintf "%d manifests, %s%d chunks, %s%s%s"
                     (int_of (mem t "manifests"))
                     approx
                     (int_of (mem t "chunks"))
                     approx
                     (Metrics.human_bytes (int_of (mem t "chunkBytes")))
                     (match mem t "sampledSecondsAgo" with
                       | `Null -> ""
                       | age ->
                           Printf.sprintf ", as of %s ago" (duration (num age))))
          )
  in

  List.iter
    (fun d ->
      line 0 "";
      line 0 "Domain %s" (str (mem d "name"));
      row 2 "settings"
        (String.concat ", "
           [
             Printf.sprintf "versioning %s"
               (if bool_of (mem d "versioning") then "on" else "off");
             Printf.sprintf "symlinks %s" (str (mem d "symlinks"));
             Printf.sprintf "chunk %s" (bytes_or_default (mem d "chunkSize"));
             Printf.sprintf "cache chunk %s"
               (bytes_or_unlimited (mem d "cacheChunkSize"));
           ]);
      (* Chunk buffers belong here and not only in a frontend block: they are
         what bounds the upload path's memory, so reading it against the chunk
         size above is how an operator sizes a small machine. *)
      row 2 "concurrency"
        (Printf.sprintf "%d uploads, %d chunk buffers, %d downloads"
           (int_of (mem d "maxUploads"))
           (int_of (mem d "maxChunkBuffers"))
           (int_of (mem d "maxDownloads")));
      (match mem d "cache" with
        | `Null -> ()
        | cache ->
            row 2 "cache"
              (Printf.sprintf "%d chunks, %s of %s%s"
                 (int_of (mem cache "chunks"))
                 (Metrics.human_bytes (int_of (mem cache "bytes")))
                 (bytes_or_unlimited (mem cache "maxCache"))
                 (match mem cache "manifests" with
                   | `Null -> ""
                   | m -> Printf.sprintf ", %d manifests" (int_of m))));
      if bool_of (mem d "domainReadOnly") then row 2 "read-only" "yes";
      (* The name this client publishes under. Silent when it is the machine's,
         which is the default and says nothing. *)
        (match str (mem d "clientName") with
        | "" -> ()
        | n when n = host -> ()
        | n -> row 2 "client name" n);
      (* Silent when there is nothing owed, which is the normal state. *)
      let wal = mem d "wal" in
      if int_of (mem wal "pending") > 0 then (
        let part name =
          match int_of (mem wal name) with
            | 0 -> None
            | n -> Some (Printf.sprintf "%d %s" n name)
        in
        row 2 "unsynced"
          (String.concat ", "
             (List.filter_map part ["intent"; "prepared"; "executed"]));
        match (int_of (mem wal "stuck"), mem wal "lastError") with
          | 0, _ | _, `Null -> ()
          | n, `String detail ->
              row 2 "stuck" (Printf.sprintf "%d, last: %s" n detail)
          | _ -> ());
      List.iter frontend_block (list (mem d "frontends"));
      List.iter backend_block (list (mem d "backends")))
    domains;

  (match processes with
    | [] -> ()
    | processes ->
        line 0 "";
        line 0 "Processes";
        List.iter
          (fun p ->
            line 2 "%-11s pid %-7d up %-8s %4.1f%% cpu  %9s rss   %s"
              (str ~default:"?" (mem p "frontend"))
              (int_of (mem p "pid"))
              (duration (num (mem p "uptimeSeconds")))
              (num (mem p "cpuPercentAvg"))
              (Metrics.human_bytes (int_of (mem p "rssBytes")))
              (String.concat ", " (List.map str (list (mem p "serves"))));
            (* Everything below is silent when clean: the second line appearing
               at all is what says this process is worth a look. *)
              (match mem p "port" with
              | `Null -> ()
              | port ->
                  row 4 "listening"
                    (Printf.sprintf "port %d, %s" (int_of port)
                       (if bool_of (mem p "tls") then "https" else "http")));
            (match
               (int_of (mem p "bytesRead"), int_of (mem p "bytesWritten"))
             with
              | 0, 0 -> ()
              | r, w ->
                  row 4 "served"
                    (Printf.sprintf "%s read (%s/s), %s written (%s/s)"
                       (Metrics.human_bytes r)
                       (Metrics.human_bytes (int_of (mem p "bytesReadPerSec")))
                       (Metrics.human_bytes w)
                       (Metrics.human_bytes
                          (int_of (mem p "bytesWrittenPerSec")))));
            (match mem p "requests" with
              | `Assoc fields ->
                  (* Counters and gauges are kept apart: a gauge of zero is an
                     idle server, a counter of zero one never asked, and
                     "0 dataWaiting" beside "2 stats" invites reading the first
                     as the second. *)
                  let is_gauge k =
                    List.mem k ["inFlight"; "dataInFlight"; "dataWaiting"]
                  in
                  let gauges, served =
                    List.partition (fun (k, _) -> is_gauge k) fields
                  in
                  let gauge k =
                    match List.assoc_opt k gauges with
                      | Some v -> int_of v
                      | None -> 0
                  in
                  let live =
                    List.filter_map
                      (fun (label, key) ->
                        match gauge key with
                          | 0 -> None
                          | n -> Some (Printf.sprintf "%d %s" n label))
                      [
                        ("in flight", "inFlight");
                        ("waiting on storage", "dataWaiting");
                      ]
                  in
                  row 4 "requests"
                    (Printf.sprintf "%s%s"
                       (if served = [] then "none served"
                        else
                          String.concat ", "
                            (List.map
                               (fun (k, v) ->
                                 Printf.sprintf "%d %s" (int_of v) k)
                               served))
                       (if live = [] then ""
                        else " (" ^ String.concat ", " live ^ ")"))
              | _ -> ());
            (match mem p "traffic" with
              | t when moved t ->
                  row 4 "traffic"
                    (Printf.sprintf "%s%s" (traffic_row t)
                       (match int_of (mem t "chunksHashed") with
                         | 0 -> ""
                         | n ->
                             Printf.sprintf ", %d chunks hashed (%d/s)" n
                               (int_of (mem t "hashesPerSec"))))
              | _ -> ());
            (* Only the pools something is waiting on: a report of empty queues
               is a report of nothing. *)
            (match
               List.filter
                 (fun p -> int_of (mem p "waiting") > 0)
                 (list (mem p "pools"))
             with
              | [] -> ()
              | busy -> row 4 "slots" (slots_row busy));
            (match int_of (mem p "swappedBytes") with
              | 0 -> ()
              | n -> row 4 "swapped" (Metrics.human_bytes n));
            match mem p "backend" with
              | `Null -> ()
              | bk -> (
                  match
                    (int_of (mem bk "retries"), int_of (mem bk "failures"))
                  with
                    | 0, 0 -> ()
                    | retries, failures ->
                        row 4 "backend"
                          (Printf.sprintf "%d retries (%d timeouts), %d failed"
                             retries
                             (int_of (mem bk "timeouts"))
                             failures)))
          processes);

  (match list (mem json "jobs") with
    | [] -> ()
    | jobs ->
        line 0 "";
        line 0 "Jobs";
        List.iter
          (fun j ->
            let sub k f = match mem j k with `Null -> () | v -> f v in
            let age = duration (num (mem j "uptimeSeconds")) in
            (* The same figure either way, so a finished job says which it is:
               time since it started reads as an age once it has stopped. *)
            let state = str (mem j "state") in
            line 2 "%s  pid %d  %s%s%s"
              (str (mem j "kind"))
              (int_of (mem j "pid"))
              (if state = "running" then Printf.sprintf "running %s" age
               else Printf.sprintf "%s, ran %s" state age)
              (match mem j "target" with `Null -> "" | t -> "  " ^ str t)
              (match mem j "error" with `Null -> "" | e -> ": " ^ str e);
            let progress = mem j "progress" in
            (* Under the name it belongs to rather than on a row of its own: a
               file the run has been on for hours is one thing, and how far into
               it the run is is the rest of that thing. *)
            sub "current" (fun c ->
                row 4 "current"
                  (elide (str c)
                  ^
                    match mem progress "current" with
                    | `Null -> ""
                    | cur ->
                        let done_ = int_of (mem cur "bytesDone")
                        and total = int_of (mem cur "bytesTotal") in
                        Printf.sprintf " · %s of %s%s"
                          (Metrics.human_bytes done_)
                          (Metrics.human_bytes total)
                          (if total > 0 then
                             Printf.sprintf " (%d%%)" (100 * done_ / total)
                           else "")));
            (* The fraction leads, and is of everything the run has behind it
               rather than of what it uploaded: a resumed import that found most
               of its tree in place is nearly through it with next to nothing
               sent. *)
              (match progress with
              | `Null -> ()
              | p ->
                  let total = int_of (mem p "bytesTotal")
                  and skipped = int_of (mem p "bytesSkipped") in
                  row 4 "progress"
                    (String.concat " · "
                       ([
                          Printf.sprintf "%d%% of %s"
                            (if total > 0 then
                               100 * int_of (mem p "bytesHandled") / total
                             else 0)
                            (Metrics.human_bytes total);
                        ]
                       @ (if skipped > 0 then
                            [
                              Printf.sprintf "%s already there"
                                (Metrics.human_bytes skipped);
                            ]
                          else [])
                       @ [
                           Printf.sprintf "%s left"
                             (Metrics.human_bytes
                                (int_of (mem p "bytesRemaining")));
                         ]
                       @
                       (* A run too young or too slow to divide by leaves the
                            estimate off rather than inventing one. *)
                       match mem p "etaSeconds" with
                         | `Null -> []
                         | e ->
                             [
                               (* A run whose estimate is against work rather
                                  than transfer publishes no rate, and the
                                  estimate stands on its own. *)
                               (match mem p "bytesPerSecAvg" with
                                 | `Null ->
                                     Printf.sprintf "~%s" (duration (num e))
                                 | r ->
                                     Printf.sprintf "~%s at %s/s avg"
                                       (duration (num e))
                                       (Metrics.human_bytes (int_of r)));
                             ])));
            (match mem j "counters" with
              | `List (_ :: _ as counters) ->
                  let pairs =
                    List.filter_map
                      (function
                        | `List [`String k; v] -> Some (k, int_of v) | _ -> None)
                      counters
                  in
                  (* A command that publishes what it planned is saying what its
                     first count is out of, so the two read as the one figure
                     they are. *)
                  let planned = List.assoc_opt "planned" pairs in
                  row 4 "counted"
                    (String.concat ", "
                       (List.filteri
                          (fun i (k, _) -> k <> "planned" || i = 0)
                          pairs
                       |> List.mapi (fun i (k, v) ->
                           match (i, planned) with
                             | 0, Some total ->
                                 Printf.sprintf "%d of %d %s" v total k
                             | _ -> Printf.sprintf "%d %s" v k)))
              | _ -> ());
            sub "traffic" (fun t ->
                row 4 "traffic"
                  (Printf.sprintf "%s, %d chunks hashed" (traffic_row t)
                     (int_of (mem t "chunksHashed"))));
            (* Live words beside the heap the process holds: the heap grows in
               steps and shrinks never, so the two together are the difference
               between something retained and an allocator that has not given
               anything back. *)
            sub "memory" (fun m ->
                let gc = mem j "gc" in
                let swapped = int_of (mem m "swappedBytes") in
                row 4 "memory"
                  (Printf.sprintf "%s rss%s, %s heap%s"
                     (Metrics.human_bytes (int_of (mem m "rssBytes")))
                     (if swapped > 0 then
                        Printf.sprintf " + %s swapped"
                          (Metrics.human_bytes swapped)
                      else "")
                     (Metrics.human_bytes (int_of (mem gc "heapBytes")))
                     (match mem gc "liveBytes" with
                       | `Null -> ""
                       | b ->
                           Printf.sprintf ", %s live"
                             (Metrics.human_bytes (int_of b)))));
            sub "deferred" (fun d ->
                row 4 "deferred"
                  (Printf.sprintf "%d queued, %d in flight"
                     (int_of (mem d "queued"))
                     (int_of (mem d "inFlight")));
                if bool_of (mem d "degraded") then
                  row 4 "" "DEGRADED, run tsync mirror");
            (match list (mem j "pools") with
              | [] -> ()
              | pools -> row 4 "slots" (slots_row pools));
            sub "backend" (fun bk ->
                match
                  (int_of (mem bk "retries"), int_of (mem bk "failures"))
                with
                  | 0, 0 -> ()
                  | retries, failures ->
                      row 4 "backend"
                        (Printf.sprintf "%d retries (%d timeouts), %d failed"
                           retries
                           (int_of (mem bk "timeouts"))
                           failures)))
          jobs);

  (match list (mem json "warnings") with
    | [] -> ()
    | warnings -> (
        line 0 "";
        line 0 "Warnings (newest first)";
        let shown = List.filteri (fun i _ -> i < warnings_shown) warnings in
        List.iter
          (fun w ->
            let t = Unix.localtime (num (mem w "lastAt")) in
            let n = int_of (mem w "count") in
            line 2 "%4s  %02d:%02d:%02d  %-5s %s"
              (if n > 1 then Printf.sprintf "×%d" n else "")
              t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec
              (str (mem w "level"))
              (str (mem w "message")))
          shown;
        match List.length warnings - List.length shown with
          | 0 -> ()
          | more ->
              line 2 "… and %s more, in tsync status --json"
                (plural more "message")));
  Buffer.contents b
