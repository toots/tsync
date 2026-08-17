open Lwt.Syntax

let interval = ref 10.
let set_interval s = interval := s

(* The heap walk behind [live_bytes] is the only expensive thing here, so it
   rides a slower cycle than the rest. *)
let deep_every = 6

type t = {
  socket_path : string;
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

(* Summed across instances rather than listed: the pools live inside functors
   applied once per domain and per role, so a process holds several under one
   name and what bounds it is their total. *)
let pools_json () =
  let by_name = Hashtbl.create 4 in
  List.iter
    (fun (name, p) ->
      let f, w, l =
        match Hashtbl.find_opt by_name name with
          | Some (f, w, l) -> (f, w, l)
          | None -> (0, 0, 0)
      in
      Hashtbl.replace by_name name
        ( f + Lwt_bounded.in_flight p,
          w + Lwt_bounded.waiting p,
          l + Lwt_bounded.limit p ))
    (Lwt_bounded.registered ());
  `List
    (Hashtbl.fold
       (fun name (f, w, l) acc ->
         `Assoc
           [
             ("name", `String name);
             ("inFlight", `Int f);
             ("waiting", `Int w);
             ("max", `Int l);
           ]
         :: acc)
       by_name [])

let payload t ~state =
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
  @ (match t.target with None -> [] | Some s -> [("target", `String s)])
  @ (match t.current () with None -> [] | Some s -> [("current", `String s)])
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
let send t ~state =
  Lwt.catch
    (fun () ->
      let line = Yojson.Safe.to_string (`Assoc (payload t ~state)) in
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
  let* () = Lwt_unix.sleep !interval in
  if t.stop then Lwt.return_unit
  else begin
    t.ticks <- t.ticks + 1;
    if t.ticks mod deep_every = 1 then t.live <- Some (Metrics.live_bytes ());
    let* () = send t ~state:"running" in
    loop t
  end

let start ~socket_path ~domain ~kind ?target ?(current = fun () -> None)
    ?(deferred = fun () -> None) ~counters () =
  let t =
    {
      socket_path;
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

let finish ?(summary = []) () =
  match !job with
    | None -> Lwt.return_unit
    | Some t ->
        t.stop <- true;
        let t = { t with counters = (fun () -> summary @ t.counters ()) } in
        send t ~state:"done"
