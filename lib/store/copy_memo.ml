open Tsync_core

(* Entries of one generation only: G moving on makes every older one dead, so
   the first use under a later G empties the memo. *)
type t = {
  m : Mutex.t;
  mutable g : int;
  held : Chunk_set.t;
  learnt : Bytes.t;  (** one flag per shard listed under [g] *)
  overflows : int ref;
  generation : unit -> int option;
}

type view = { memo : t; g : int option }

let forget_shards learnt = Bytes.fill learnt 0 4096 '\000'

let create ~generation () =
  let learnt = Bytes.make 4096 '\000' and overflows = ref 0 in
  {
    m = Mutex.create ();
    g = 0;
    held =
      Chunk_set.create
        ~on_overflow:(fun () ->
          forget_shards learnt;
          incr overflows)
        ();
    learnt;
    overflows;
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

(* Whether entries may be recorded under [g]; the memo's lock is held. *)
let current (memo : t) g =
  if g > memo.g then (
    Chunk_set.clear memo.held;
    forget_shards memo.learnt;
    memo.g <- g);
  g = memo.g

let shard_index = Chunk_set.shard_index

let holds v ck =
  match v.g with
    | None -> false
    | Some g ->
        Mutex.protect v.memo.m (fun () ->
            g = v.memo.g && Chunk_set.mem v.memo.held ck)

let note v ck =
  match v.g with
    | None -> ()
    | Some g ->
        Mutex.protect v.memo.m (fun () ->
            if current v.memo g then Chunk_set.add v.memo.held ck)

let learn_shard v sss list =
  match v.g with
    | None -> ()
    | Some g ->
        let i = shard_index sss in
        if
          Mutex.protect v.memo.m (fun () ->
              not (g = v.memo.g && Bytes.get v.memo.learnt i = '\001'))
        then (
          let cks = list () in
          Mutex.protect v.memo.m (fun () ->
              if current v.memo g then (
                let before = !(v.memo.overflows) in
                List.iter (Chunk_set.add v.memo.held) cks;
                (* A-7.10: a shard is known only with every key it listed. *)
                if !(v.memo.overflows) = before then
                  Bytes.set v.memo.learnt i '\001')))

let forget (memo : t) cks =
  Mutex.protect memo.m (fun () ->
      List.iter
        (fun ck ->
          Chunk_set.remove memo.held ck;
          Bytes.set memo.learnt (shard_index (Chunk_key.shard ck)) '\000')
        cks)
