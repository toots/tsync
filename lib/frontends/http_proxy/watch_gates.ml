open Tsync_core
open Tsync_store

let watch_retry = 30.

type gate = {
  token : string option Atomic.t;
  mutable waiters : int;
  mutable watching : bool;
  woken : Rt.Signal.t;
}

type t = { m : Mutex.t; gates : (string * string, gate) Hashtbl.t }

let create () = { m = Mutex.create (); gates = Hashtbl.create 4 }
let read (store : Store.t) k = Store.token (store.get_opt k)

let differs current last_seen =
  match (last_seen, current) with
    | None, c -> c <> None
    | Some l, c -> c <> Some l

(* Runs while waiters remain; the check that ends it and a newcomer's start
   are one step under [t.m]. *)
let rec loop t id g (store : Store.t) k =
  let continue_ =
    Mutex.protect t.m (fun () ->
        if g.waiters = 0 then (
          g.watching <- false;
          Hashtbl.remove t.gates id;
          false)
        else true)
  in
  if continue_ then (
    (try
       store.watch k (Atomic.get g.token);
       Atomic.set g.token (read store k);
       Rt.Signal.broadcast g.woken
     with
      | Stop.Stopping -> raise Stop.Stopping
      | e ->
          Log.info "watch %s: %s" (Key.to_string k) (Printexc.to_string e);
          Stop.sleep watch_retry);
    loop t id g store k)

let wait t ~route ~store k ~last_seen ~wait =
  let id = (route, Key.to_string k) in
  let g, start =
    Mutex.protect t.m (fun () ->
        let g =
          match Hashtbl.find_opt t.gates id with
            | Some g -> g
            | None ->
                let g =
                  {
                    token = Atomic.make None;
                    waiters = 0;
                    watching = false;
                    woken = Rt.Signal.create ();
                  }
                in
                Hashtbl.replace t.gates id g;
                g
        in
        g.waiters <- g.waiters + 1;
        let start = not g.watching in
        g.watching <- true;
        (g, start))
  in
  Fun.protect
    ~finally:(fun () ->
      Mutex.protect t.m (fun () -> g.waiters <- g.waiters - 1))
    (fun () ->
      Atomic.set g.token (read store k);
      if start then
        Rt.spawn ~name:"watch gate" (fun () ->
            try loop t id g store k with Stop.Stopping -> ());
      let deadline = Rt.now () +. wait in
      let rec hold () =
        let v = Rt.Signal.version g.woken in
        if differs (Atomic.get g.token) last_seen then `Changed
        else (
          let left = deadline -. Rt.now () in
          if left <= 0. then `Unchanged
          else (
            (try
               Rt.with_timeout left (fun () -> Rt.Signal.wait ~since:v g.woken)
             with Rt.Timeout -> ());
            hold ()))
      in
      hold ())
