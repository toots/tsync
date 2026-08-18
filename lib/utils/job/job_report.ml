open Lwt.Syntax

(* The heap walk behind [live_bytes] is the only expensive thing here, so it
   rides a slower cycle than the rest. *)
let deep_every = 6

type t = {
  socket_path : string;
  interval : float;
  domain : string;
  kind : string;
  target : string option;
  started : float;
  current : unit -> string option;
  deferred : unit -> (int * int * bool) option;
  counters : unit -> (string * int) list;
  mutable ticks : int;
  mutable live : int option;
  mutable stop : bool;
  mutable warned : bool;
}

let job : t option ref = ref None
let ints l = `List (List.map (fun (k, v) -> `List [`String k; `Int v]) l)

let pools_json () =
  `List
    (List.map
       (fun (name, in_flight, waiting, limit) ->
         `Assoc
           [
             ("name", `String name);
             ("inFlight", `Int in_flight);
             ("waiting", `Int waiting);
             ("max", `Int limit);
           ])
       (Lwt_bounded.totals ()))

let payload t ~state ~extra =
  let m = Metrics.mem_stats () in
  let g = Metrics.gc_stats () in
  let gc =
    [
      ("heapBytes", `Int g.Metrics.heap_bytes);
      ("topHeapBytes", `Int g.Metrics.top_heap_bytes);
      ("minorCollections", `Int g.Metrics.minor_collections);
      ("majorCollections", `Int g.Metrics.major_collections);
    ]
    @ match t.live with None -> [] | Some b -> [("liveBytes", `Int b)]
  in
  [
    ("action", `String "report");
    ("kind", `String t.kind);
    ("domain", `String t.domain);
    ("pid", `Int (Unix.getpid ()));
    ("startedAt", `Float t.started);
    (* Elapsed is computed here and not by the reader: a report is rendered on
       whatever host asked for it, whose clock is not this one. *)
    ("uptimeSeconds", `Float (Unix.gettimeofday () -. t.started));
    (* So a reader can tell silence from a slow cadence without knowing what
       this process was built with. *)
    ("intervalSeconds", `Float t.interval);
    ("state", `String state);
    ( "memory",
      `Assoc
        [
          ("rssBytes", `Int m.Metrics.rss);
          ("privateBytes", `Int m.Metrics.private_);
          ("swappedBytes", `Int m.Metrics.swapped);
          ("virtBytes", `Int m.Metrics.virt);
          ("systemUsedBytes", `Int m.Metrics.system_used);
          ("systemTotalBytes", `Int m.Metrics.system_total);
        ] );
    ("gc", `Assoc gc);
    ( "traffic",
      `Assoc
        [
          ("bytesUploaded", `Int (Metrics.uploaded ()));
          ("uploadBytesPerSec", `Int (int_of_float (Metrics.upload_rate ())));
          ("bytesDownloaded", `Int (Metrics.downloaded ()));
          ("downloadBytesPerSec", `Int (int_of_float (Metrics.download_rate ())));
          ("chunksHashed", `Int (Metrics.hashed ()));
        ] );
    ( "backend",
      `Assoc
        [
          ("retries", `Int (Metrics.retries ()));
          ("timeouts", `Int (Metrics.timeouts ()));
          ("failures", `Int (Metrics.failures ()));
        ] );
    ("pools", pools_json ());
    ("counters", ints (t.counters ()));
  ]
  @ extra
  @ (match t.target with None -> [] | Some s -> [("target", `String s)])
  @ (match t.current () with None -> [] | Some s -> [("current", `String s)])
  @ Job_progress.json ()
  @
    match t.deferred () with
    | None -> []
    | Some (queued, in_flight, degraded) ->
        [
          ( "deferred",
            `Assoc
              [
                ("queued", `Int queued);
                ("inFlight", `Int in_flight);
                ("degraded", `Bool degraded);
              ] );
        ]

(* Every failure here is silence in a status listing, so it is swallowed: a
   command must not die because nothing was listening, and the daemon being
   absent is the ordinary case rather than an error. Said once, so a run without
   a daemon does not print a line a minute. *)
let send t ~state ?(extra = []) () =
  Lwt.catch
    (fun () ->
      let line = Yojson.Safe.to_string (`Assoc (payload t ~state ~extra)) in
      let+ (_ : string) = Ipc.send_lwt ~socket_path:t.socket_path line in
      ())
    (fun exn ->
      if not t.warned then begin
        t.warned <- true;
        Log.debug "job report: %s (reporting disabled for this run)"
          (Printexc.to_string exn)
      end;
      Lwt.return_unit)

let rec loop t =
  let* () = Lwt_unix.sleep t.interval in
  if t.stop then Lwt.return_unit
  else begin
    t.ticks <- t.ticks + 1;
    if t.ticks mod deep_every = 1 then t.live <- Some (Metrics.live_bytes ());
    let* () = send t ~state:"running" () in
    loop t
  end

let start ~socket_path ~domain ~kind ?target ?(interval = 10.)
    ?(current = fun () -> None) ?(deferred = fun () -> None) ~counters () =
  let t =
    {
      socket_path;
      interval;
      domain;
      kind;
      target;
      started = Unix.gettimeofday ();
      current;
      deferred;
      counters;
      ticks = 0;
      live = None;
      stop = false;
      warned = false;
    }
  in
  job := Some t;
  (* Sequential by construction: a slow send delays the next tick rather than
     overlapping it, and [send] cannot raise, so nothing reaches
     [Lwt.async_exception_hook] — which would take the command down with it. *)
  Lwt.async (fun () -> loop t)

let finish ?error () =
  match !job with
    | None -> Lwt.return_unit
    | Some t ->
        t.stop <- true;
        job := None;
        let state = match error with None -> "done" | Some _ -> "failed" in
        let extra =
          Option.to_list (Option.map (fun e -> ("error", `String e)) error)
        in
        send t ~state ~extra ()
