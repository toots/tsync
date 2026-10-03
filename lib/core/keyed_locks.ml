type entry = {
  lock : Rt.Fmutex.t;
  mutable generation : int;
  mutable users : int;
}

type t = { m : Mutex.t; entries : (string, entry) Hashtbl.t }

let create () = { m = Mutex.create (); entries = Hashtbl.create 64 }

let entry t key =
  match Hashtbl.find_opt t.entries key with
    | Some e -> e
    | None ->
        let e = { lock = Rt.Fmutex.create (); generation = 0; users = 0 } in
        Hashtbl.replace t.entries key e;
        e

(* ponytail: a bumped key keeps its entry for the process's life, since a
   reader may compare its generation across two holds; give readers a handle
   that pins the entry if a million edited paths ever show in memory. *)
let with_key t key f =
  let e =
    Mutex.protect t.m (fun () ->
        let e = entry t key in
        e.users <- e.users + 1;
        e)
  in
  Fun.protect
    ~finally:(fun () ->
      Mutex.protect t.m (fun () ->
          e.users <- e.users - 1;
          if e.users = 0 && e.generation = 0 then Hashtbl.remove t.entries key))
    (fun () -> Rt.Fmutex.with_lock e.lock f)

let generation t key =
  Mutex.protect t.m (fun () ->
      match Hashtbl.find_opt t.entries key with
        | Some e -> e.generation
        | None -> 0)

let bump t key =
  Mutex.protect t.m (fun () ->
      let e = entry t key in
      e.generation <- e.generation + 1)

let size t = Mutex.protect t.m (fun () -> Hashtbl.length t.entries)
