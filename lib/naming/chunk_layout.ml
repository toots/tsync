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
