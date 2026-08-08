(* Where a chunk key lives, relative to a chunk store's root. Shared by the
   backend store and the local cache: both are keyed by the same fixed-length hex
   "<h1>-<h2>", and neither wants every chunk in one directory.

   Three characters splits a store 4096 ways: a few hundred files per shard for a
   10 TB store at the default chunk size, small enough that readdir stays cheap
   without tens of thousands of near-empty directories. *)
let fanout = 3
let shards = 1 lsl (4 * fanout)
let shard_name n = Printf.sprintf "%0*x" fanout n

let relative_path key =
  let shard =
    if String.length key >= fanout then String.sub key 0 fanout else "_"
  in
  Filename.concat shard key

(* Whether a name in a shard is a chunk and not something else that ended up
   there — a write that was in flight when a directory was moved, or anything a
   person left behind.

   Stated as what a chunk key *is*, not as what it is not: a caller walking a
   shard has to decide about every name it finds, and a rule that lists the
   exceptions quietly admits whatever nobody thought of. Which for a caller that
   copies what it finds means copying rubbish, and for one that deletes what it
   does not recognise would mean rather worse.

   Two digests of {!Xxhash.hash_hex} joined by a dash, which is what
   {!Manifest.chunk_key} builds and the only thing this layout ever files. *)
let digest_hex = 16
let key_length = (2 * digest_hex) + 1

let is_hex c =
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

let is_chunk_key name =
  String.length name = key_length
  && name.[digest_hex] = '-'
  && String.for_all (fun c -> is_hex c || c = '-') name
