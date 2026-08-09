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

(* Whether a name in a shard is a chunk, and whether a name in the chunk root is
   a shard. Both are asked while walking a directory, where the answer decides
   whether something gets copied or deleted -- see {!Xxhash.is_hex} for why they
   are stated as what the name is.

   A chunk key is what {!Manifest.chunk_key} builds: two digests and a dash. A
   shard is {!shard_name}: [fanout] hex characters. *)
let is_chunk_key name =
  match String.index_opt name '-' with
    | Some i when i = Xxhash.hex_length ->
        Xxhash.is_hex (String.sub name 0 i)
        && Xxhash.is_hex (String.sub name (i + 1) (String.length name - i - 1))
    | _ -> false

let is_shard_name name =
  String.length name = fanout
  && String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       name
