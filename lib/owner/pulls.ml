open Tsync_core
open Tsync_sync

type params = {
  pull_freshness : float;
  view_max_age : float;
  pull_patience : float;
  refresh_patience : float;
  pull_page : int;
}

let default =
  {
    pull_freshness = 5.;
    view_max_age = 10. *. 86400.;
    pull_patience = 2.;
    refresh_patience = 20.;
    pull_page = 256;
  }

type t = {
  params : params;
  engine : (module Engine.S);
  silent : unit -> bool;
  changed : string list -> unit;
  recovered : unit -> unit;
  m : Mutex.t;
  fresh : (string, float) Hashtbl.t;
      (** folder id → monotonic time of this process's last completed pull *)
  owed_notice : (string, bool) Hashtbl.t;
      (** folders answered outdated while their pull ran, and whether that
          answer said offline *)
  unreachable : bool Atomic.t;
  passes : passes;
  passes_m : Mutex.t;
}

(* android §3.2: the pass running, and the one that follows it for the
   refreshes made meanwhile. *)
and passes = {
  mutable running : Protocol.pass_summary option Rt.Promise.t option;
  mutable queued : Protocol.pass_summary option Rt.Promise.t option;
}

type view = { pulled_at : float option; outdated : bool; offline : bool }

let create ?(params = default) ~engine ~silent ~changed ~recovered () =
  {
    params;
    engine;
    silent;
    changed;
    recovered;
    m = Mutex.create ();
    fresh = Hashtbl.create 16;
    owed_notice = Hashtbl.create 4;
    unreachable = Atomic.make false;
    passes = { running = None; queued = None };
    passes_m = Mutex.create ();
  }

let note_unreachable t = Atomic.set t.unreachable true

let succeeded t =
  if Atomic.exchange t.unreachable false then (
    try t.recovered () with _ -> ())

(* Freshness is per process and monotonic (android §10); by folder id, which a
   rename keeps. *)
let key t dir =
  let (module E : Engine.S) = t.engine in
  Option.map Folder_id.to_string (E.folder_id dir)

let fresh_key t k =
  Mutex.protect t.m (fun () ->
      match Hashtbl.find_opt t.fresh k with
        | Some at -> Rt.now () -. at < t.params.pull_freshness
        | None -> false)

let is_fresh t dir = Option.fold ~none:false ~some:(fresh_key t) (key t dir)

(* Detached: a waiter that gives up leaves the pull running. *)
let start t dir =
  let (module E : Engine.S) = t.engine in
  let k = key t dir in
  let done_ = Rt.Promise.create () in
  Rt.spawn ~name:"pull" (fun () ->
      let outcome =
        match E.pull ~page:t.params.pull_page dir with
          | differs ->
              let owed =
                Mutex.protect t.m (fun () ->
                    Option.iter
                      (fun k -> Hashtbl.replace t.fresh k (Rt.now ()))
                      k;
                    let owed = Hashtbl.mem t.owed_notice dir in
                    Hashtbl.remove t.owed_notice dir;
                    owed)
              in
              succeeded t;
              if differs || owed then (try t.changed [dir] with _ -> ());
              Ok ()
          | exception (Fail.E { kind = Unreachable; _ } as e) ->
              (* android §3.2: an answer that said online is listed again,
                 now offline; one that said offline already is not, or each
                 relisting's pull would notify again. Under [t.m] with
                 [stale]'s check, so an answer either says offline or is
                 owed this notice. *)
              let said_online =
                Mutex.protect t.m (fun () ->
                    note_unreachable t;
                    match Hashtbl.find_opt t.owed_notice dir with
                      | Some false ->
                          Hashtbl.remove t.owed_notice dir;
                          true
                      | _ -> false)
              in
              if said_online then (try t.changed [dir] with _ -> ());
              Error e
          | exception e -> Error e
      in
      ignore (Rt.Promise.try_resolve_result done_ outcome));
  done_

(* [`Done], or why the caller goes on without the store. *)
let wait_patiently t done_ =
  if t.silent () then `Offline
  else (
    match
      Rt.with_timeout t.params.pull_patience (fun () -> Rt.Promise.await done_)
    with
      | () -> `Done
      | exception Rt.Timeout -> `Slow
      | exception e when not (Rt.is_cancelled e) -> `Failed e)

let has_view t dir =
  let (module E : Engine.S) = t.engine in
  let now = Unix.gettimeofday () in
  match E.pulled_at dir with
    | None -> false
    | Some at -> (
        now -. at < t.params.view_max_age
        || match E.view_hold dir with Some h -> h > now | None -> false)

(* A page after the first continues the view its first page was answered
   from: outdated only when this process never completed a pull of the folder. *)
let continued t dir =
  let (module E : Engine.S) = t.engine in
  let pulled =
    match key t dir with
      | Some k -> Mutex.protect t.m (fun () -> Hashtbl.mem t.fresh k)
      | None -> false
  in
  {
    pulled_at = E.pulled_at dir;
    outdated = not pulled;
    offline = t.silent () || Atomic.get t.unreachable;
  }

let for_listing t ~pull dir =
  let (module E : Engine.S) = t.engine in
  let offline () = t.silent () || Atomic.get t.unreachable in
  let fresh () =
    { pulled_at = E.pulled_at dir; outdated = false; offline = false }
  in
  let stale () =
    let offline =
      Mutex.protect t.m (fun () ->
          let offline = offline () in
          Hashtbl.replace t.owed_notice dir offline;
          offline)
    in
    { pulled_at = E.pulled_at dir; outdated = true; offline }
  in
  match pull with
    | `Never ->
        {
          pulled_at = E.pulled_at dir;
          outdated = not (is_fresh t dir);
          offline = offline ();
        }
    | (`Auto | `Background) when is_fresh t dir -> fresh ()
    | `Background ->
        (* The answer's owed notice is recorded before its pull can end. *)
        if has_view t dir then (
          let view = stale () in
          ignore (start t dir);
          view)
        else (
          Rt.Promise.await (start t dir);
          fresh ())
    | `Auto | `Now ->
        let done_ = start t dir in
        if has_view t dir then (
          match wait_patiently t done_ with
            | `Done -> fresh ()
            | `Offline ->
                Atomic.set t.unreachable true;
                stale ()
            | `Slow -> stale ()
            | `Failed e ->
                Log.info "pull of %S failed: %s" dir (Printexc.to_string e);
                stale ())
        else (
          Rt.Promise.await done_;
          fresh ())

(* publication §4.11: a folder with no view has nothing a name could be checked
   against, unless this client made it. *)
let before_mutation t dir =
  let (module E : Engine.S) = t.engine in
  if not (is_fresh t dir) then
    if E.pulled_at dir = None && not (E.created_here dir) then
      Rt.Promise.await (start t dir)
    else ignore (wait_patiently t (start t dir))

let for_walk t dir = if not (is_fresh t dir) then Rt.Promise.await (start t dir)

let before_open t path =
  let (module E : Engine.S) = t.engine in
  let done_ = Rt.Promise.create () in
  Rt.spawn ~name:"refresh" (fun () ->
      ignore
        (Rt.Promise.try_resolve_result done_
           (match E.refresh_file ~page:t.params.pull_page path with
             | () ->
                 succeeded t;
                 Ok ()
             | exception e -> Error e)));
  ignore (wait_patiently t done_)

let stamp_fresh t dirs =
  let now = Rt.now () in
  let keys = List.filter_map (key t) dirs in
  Mutex.protect t.m (fun () ->
      List.iter (fun k -> Hashtbl.replace t.fresh k now) keys;
      List.filter
        (fun dir ->
          let owed = Hashtbl.mem t.owed_notice dir in
          Hashtbl.remove t.owed_notice dir;
          owed)
        dirs)

let summary (pass : Engine_intf.pass) : Protocol.pass_summary =
  {
    held = pass.held;
    covered = List.length pass.covered;
    merged = List.length pass.changed;
    entries = pass.entries;
    ended =
      (match pass.ended with
        | `Head -> "head"
        | `Stopped -> "stopped"
        | `Pruned -> "pruned"
        | `Unreadable -> "unreadable"
        | `Fresh -> "fresh");
    error = None;
  }

let run_pass t : Protocol.pass_summary =
  let (module E : Engine.S) = t.engine in
  match
    E.pull_pass ~page:t.params.pull_page ~stop:t.silent
      ~fresh:(fun id -> fresh_key t (Folder_id.to_string id))
      ()
  with
    | pass ->
        let owed = stamp_fresh t pass.covered in
        if pass.covered <> [] then succeeded t;
        let notice = List.sort_uniq String.compare (pass.changed @ owed) in
        if notice <> [] then (try t.changed notice with _ -> ());
        summary pass
    | exception e when not (Rt.is_cancelled e) ->
        Log.info "refresh pass failed: %s" (Printexc.to_string e);
        {
          held = 0;
          covered = 0;
          merged = 0;
          entries = 0;
          ended = "failed";
          error = Some (Printexc.to_string e);
        }

(* Each pass resolves its promise, then starts the queued one, if any. *)
let rec start_pass t mine =
  Rt.spawn ~name:"refresh pass" (fun () ->
      let next = ref None in
      Fun.protect
        ~finally:(fun () ->
          ignore (Rt.Promise.try_resolve mine None);
          Option.iter (start_pass t) !next)
        (fun () ->
          let result =
            try Some (run_pass t)
            with e ->
              (* A cancelled pass gives up its successor too. *)
              Mutex.protect t.passes_m (fun () ->
                  Option.iter
                    (fun q -> ignore (Rt.Promise.try_resolve q None))
                    t.passes.queued;
                  t.passes.running <- None;
                  t.passes.queued <- None);
              raise e
          in
          Mutex.protect t.passes_m (fun () ->
              t.passes.running <- t.passes.queued;
              next := t.passes.queued;
              t.passes.queued <- None);
          ignore (Rt.Promise.try_resolve mine result)))

(* A refresh made while a pass runs waits for the next one, which reads what
   landed after the running one read the log. *)
let refresh t =
  let pass, starts =
    Mutex.protect t.passes_m (fun () ->
        match t.passes with
          | { running = None; _ } ->
              let p = Rt.Promise.create () in
              t.passes.running <- Some p;
              (p, true)
          | { queued = Some q; _ } -> (q, false)
          | { queued = None; _ } ->
              let q = Rt.Promise.create () in
              t.passes.queued <- Some q;
              (q, false))
  in
  if starts then start_pass t pass;
  (* ios §5.1: the host is kept running while this request is pending. *)
  try
    Rt.with_timeout t.params.refresh_patience (fun () -> Rt.Promise.await pass)
  with Rt.Timeout -> None
