let width = 16

type shard = { mutable keys : Bytes.t; mutable count : int }

type t = {
  shards : shard array;
  mutable total : int;
  max : int;
  on_overflow : unit -> unit;
}

(* ponytail: past [max] the whole set is dropped rather than its least used
   shards; evict by shard if a domain of that size ever exists. *)
let create ?(max = 8_000_000) ?(on_overflow = ignore) () =
  {
    shards = Array.init 4096 (fun _ -> { keys = Bytes.empty; count = 0 });
    total = 0;
    max;
    on_overflow;
  }

let nibble c =
  match c with
    | '0' .. '9' -> Char.code c - 48
    | 'a' .. 'f' -> Char.code c - 87
    | _ -> invalid_arg "Chunk_set: not a chunk key"

(* A key is two runs of 16 hex digits around a dash. *)
let pack ck =
  let s = Chunk_key.to_string ck in
  Bytes.init width (fun i ->
      let at = (2 * i) + if i >= 8 then 1 else 0 in
      Char.chr ((nibble s.[at] lsl 4) lor nibble s.[at + 1]))

let shard_of t packed =
  t.shards.((Char.code (Bytes.get packed 0) lsl 4)
            lor (Char.code (Bytes.get packed 1) lsr 4))

let find sh packed =
  let rec at i =
    if i = sh.count then None
    else if
      Bytes.get_int64_ne sh.keys (i * width) = Bytes.get_int64_ne packed 0
      && Bytes.get_int64_ne sh.keys ((i * width) + 8)
         = Bytes.get_int64_ne packed 8
    then Some i
    else at (i + 1)
  in
  at 0

let mem t ck =
  let packed = pack ck in
  find (shard_of t packed) packed <> None

let clear t =
  Array.iter
    (fun sh ->
      sh.keys <- Bytes.empty;
      sh.count <- 0)
    t.shards;
  t.total <- 0

let add t ck =
  let packed = pack ck in
  let sh = shard_of t packed in
  if find sh packed = None then (
    if t.total >= t.max then (
      clear t;
      t.on_overflow ());
    if (sh.count + 1) * width > Bytes.length sh.keys then (
      let grown = Bytes.create (max (4 * width) (2 * Bytes.length sh.keys)) in
      Bytes.blit sh.keys 0 grown 0 (sh.count * width);
      sh.keys <- grown);
    Bytes.blit packed 0 sh.keys (sh.count * width) width;
    sh.count <- sh.count + 1;
    t.total <- t.total + 1)

let remove t ck =
  let packed = pack ck in
  let sh = shard_of t packed in
  match find sh packed with
    | None -> ()
    | Some i ->
        Bytes.blit sh.keys ((sh.count - 1) * width) sh.keys (i * width) width;
        sh.count <- sh.count - 1;
        t.total <- t.total - 1

let clear_shard t sss =
  let sh = t.shards.(int_of_string ("0x" ^ sss)) in
  t.total <- t.total - sh.count;
  sh.keys <- Bytes.empty;
  sh.count <- 0

let unpack keys at =
  let hex off =
    String.concat ""
      (List.init 8 (fun i ->
           Printf.sprintf "%02x" (Char.code (Bytes.get keys (at + off + i)))))
  in
  Chunk_key.v (hex 0 ^ "-" ^ hex 8)

let elements t =
  Array.fold_right
    (fun sh acc ->
      List.init sh.count (fun i -> unpack sh.keys (i * width)) @ acc)
    t.shards []

let cardinal t = t.total
