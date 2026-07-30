(* Where a chunk key lives, as a path relative to a chunk store's root. The
   backend store and the local cache share this: both are keyed by the same
   fixed-length hex "<h1>-<h2>", and neither wants every chunk in one directory.

   Three characters splits a store 4096 ways. At the default 8 MiB chunk size
   that is a few hundred files per shard for a 10 TB store — small enough that
   readdir stays cheap, without paying for tens of thousands of directories that
   would sit near-empty. *)
let fanout = 3

let relative_path key =
  let shard =
    if String.length key >= fanout then String.sub key 0 fanout else "_"
  in
  Filename.concat shard key
