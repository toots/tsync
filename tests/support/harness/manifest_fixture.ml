(* Building a manifest from chunk keys, which only a test does: an upload fills
   a builder as it hashes, and publishes with the digests it accumulated. *)

type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

let chunk_key (entry : chunk_entry) = entry.h1 ^ "-" ^ entry.h2

let entry_of_key ~index ~size key =
  match String.index_opt key '-' with
    | Some i ->
        {
          index;
          h1 = String.sub key 0 i;
          h2 = String.sub key (i + 1) (String.length key - i - 1);
          size;
        }
    | None -> invalid_arg ("Manifest_fixture.entry_of_key: " ^ key)

let make ~name ~h1 ~h2 ~size ~chunk_size ~chunks ~mtime =
  Manifest.of_string
    (Manifest.encode ~name ~size ~chunk_size ~mtime ~h1 ~h2 ~symlink:None
       ~keys:(List.map chunk_key chunks))
