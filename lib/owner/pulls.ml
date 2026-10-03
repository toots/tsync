open Tsync_core
open Tsync_sync

type params = {
  pull_freshness : float;
  view_max_age : float;
  pull_patience : float;
}

let default =
  { pull_freshness = 5.; view_max_age = 10. *. 86400.; pull_patience = 2. }

type t = {
  params : params;
  engine : (module Engine.S);
  silent : unit -> bool;
  changed : string list -> unit;
  recovered : unit -> unit;
  m : Mutex.t;
  fresh : (string, float) Hashtbl.t;
      (** folder id → monotonic time of this process's last completed pull *)
  owed_notice : (string, unit) Hashtbl.t;
      (** folders answered outdated while their pull ran *)
  offline : bool Atomic.t;
}

type view = { pulled_at : float option; outdated : bool }

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
    offline = Atomic.make false;
  }

let note_unreachable t = Atomic.set t.offline true

let succeeded t =
  if Atomic.exchange t.offline false then (try t.recovered () with _ -> ())

(* Freshness is per process and monotonic (android §10); by folder id, which a
   rename keeps. *)
let key t dir =
  let (module E : Engine.S) = t.engine in
  Option.map Folder_id.to_string (E.folder_id dir)

let is_fresh t dir =
  match key t dir with
    | None -> false
    | Some k ->
        Mutex.protect t.m (fun () ->
            match Hashtbl.find_opt t.fresh k with
              | Some at -> Rt.now () -. at < t.params.pull_freshness
              | None -> false)

(* Detached: a waiter that gives up leaves the pull running. *)
let start t dir =
  let (module E : Engine.S) = t.engine in
  let k = key t dir in
  let done_ = Rt.Promise.create () in
  Rt.spawn ~name:"pull" (fun () ->
      let outcome =
        match E.pull dir with
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
  { pulled_at = E.pulled_at dir; outdated = not pulled }

let for_listing t ~pull dir =
  let (module E : Engine.S) = t.engine in
  let fresh () = { pulled_at = E.pulled_at dir; outdated = false } in
  let stale () =
    Mutex.protect t.m (fun () -> Hashtbl.replace t.owed_notice dir ());
    { pulled_at = E.pulled_at dir; outdated = true }
  in
  match pull with
    | `Never -> { pulled_at = E.pulled_at dir; outdated = not (is_fresh t dir) }
    | `Auto when is_fresh t dir -> fresh ()
    | `Auto | `Now ->
        let done_ = start t dir in
        if has_view t dir then (
          match wait_patiently t done_ with
            | `Done -> fresh ()
            | `Offline ->
                Atomic.set t.offline true;
                stale ()
            | `Slow -> stale ()
            | `Failed e ->
                Log.info "pull of %S failed: %s" dir (Printexc.to_string e);
                stale ())
        else (
          Rt.Promise.await done_;
          fresh ())

let before_mutation t dir =
  if not (is_fresh t dir) then ignore (wait_patiently t (start t dir))

let for_walk t dir = if not (is_fresh t dir) then Rt.Promise.await (start t dir)

let before_open t path =
  let (module E : Engine.S) = t.engine in
  let done_ = Rt.Promise.create () in
  Rt.spawn ~name:"refresh" (fun () ->
      ignore
        (Rt.Promise.try_resolve_result done_
           (match E.refresh_file path with
             | () ->
                 succeeded t;
                 Ok ()
             | exception e -> Error e)));
  ignore (wait_patiently t done_)
