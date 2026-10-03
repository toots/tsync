open Tsync_core

type t = {
  m : Mutex.t;
  held : (string, int) Hashtbl.t;
  shards : (string, int) Hashtbl.t;
  generation : unit -> int option;
}

type view = { memo : t; g : int option }

let create ~generation () =
  {
    m = Mutex.create ();
    held = Hashtbl.create 1024;
    shards = Hashtbl.create 64;
    generation;
  }

let look memo =
  {
    memo;
    g =
      (match memo.generation () with
        | Some g when g mod 2 = 0 -> Some g
        | _ -> None);
  }

let trusted v = v.g <> None

let holds v ck =
  match v.g with
    | None -> false
    | Some g ->
        Mutex.protect v.memo.m (fun () ->
            Hashtbl.find_opt v.memo.held (Chunk_key.to_string ck) = Some g)

let note v ck =
  match v.g with
    | None -> ()
    | Some g ->
        Mutex.protect v.memo.m (fun () ->
            Hashtbl.replace v.memo.held (Chunk_key.to_string ck) g)

let learn_shard v sss list =
  match v.g with
    | None -> ()
    | Some g ->
        if
          Mutex.protect v.memo.m (fun () ->
              Hashtbl.find_opt v.memo.shards sss <> Some g)
        then (
          let cks = list () in
          Mutex.protect v.memo.m (fun () ->
              List.iter
                (fun ck ->
                  Hashtbl.replace v.memo.held (Chunk_key.to_string ck) g)
                cks;
              Hashtbl.replace v.memo.shards sss g))

let forget memo cks =
  Mutex.protect memo.m (fun () ->
      List.iter
        (fun ck ->
          Hashtbl.remove memo.held (Chunk_key.to_string ck);
          Hashtbl.remove memo.shards (Chunk_key.shard ck))
        cks)
