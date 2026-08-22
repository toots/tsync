(* A published file's metadata is the body it was decoded from: the header
   fields are answered by reading it rather than copied out beside it, and the
   chunk keys are never materialized to answer what the file is called. *)
type t = Chunk_table.t

let size = Chunk_table.size
let chunk_size = Chunk_table.chunk_size
let h1 = Chunk_table.h1
let h2 = Chunk_table.h2
let mtime = Chunk_table.mtime
let symlink = Chunk_table.symlink

(* Only the location can say whether this is worth consulting, so a caller
   holding a key uses the key instead. *)
let recorded_name = Chunk_table.name

(* What an upload produces per chunk. Read paths go through the table. *)
type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

let chunk_key (entry : chunk_entry) = entry.h1 ^ "-" ^ entry.h2

(* The reverse, for a chunk kept from a previous upload: the two digests are the
   key's halves. *)
let entry_of_key ~index ~size key =
  match String.index_opt key '-' with
    | Some i ->
        {
          index;
          h1 = String.sub key 0 i;
          h2 = String.sub key (i + 1) (String.length key - i - 1);
          size;
        }
    | None -> invalid_arg ("Manifest.entry_of_key: " ^ key)

(* Hashed over the ordered chunk digests, so a changed file's manifest rebuilds
   from its chunk entries without re-reading untouched bytes.

   What one chunk contributes is spelled once below: an upload that addresses
   its keys and a caller holding them as a list must reach the same digest for
   the same file, and two spellings of this line is how that stops being true. *)
let chunk_digest ~key ~size = Printf.sprintf "%s-%d;" key size

let digest_fold feed =
  let s1 = Xxhash.create 0 and s2 = Xxhash.create 1 in
  feed (fun d ->
      Xxhash.update s1 d;
      Xxhash.update s2 d);
  (Xxhash.digest_hex s1, Xxhash.digest_hex s2)

let digest_of_chunks chunks =
  digest_fold (fun add ->
      List.iter
        (fun (c : chunk_entry) ->
          add (chunk_digest ~key:(chunk_key c) ~size:c.size))
        chunks)

let digest_of_keys ~count ~key ~len =
  digest_fold (fun add ->
      for i = 0 to count - 1 do
        add (chunk_digest ~key:(key i) ~size:(len i))
      done)

let of_table chunks = chunks
let of_string s = of_table (Chunk_table.of_string s)
let of_chunk c = of_table (Chunk_table.of_chunk c)

(* Mapped: chunk keys cost no heap and the pages are reclaimable. *)
let of_file path = of_table (Chunk_table.of_file path)

(* Encoding needs a name, so every caller states one; a version snapshot and a
   trashed marker are the only ones passing anything but the key's own leaf. *)
let to_string ~name (m : t) =
  Chunk_table.encode ~name ~size:(size m) ~chunk_size:(chunk_size m)
    ~mtime:(mtime m) ~h1:(h1 m) ~h2:(h2 m) ~symlink:(symlink m)
    ~keys:(List.init (Chunk_table.count m) (Chunk_table.key m))

let body ~name m =
  if recorded_name m = name then Chunk_table.bytes m
  else Bigstring.of_string (to_string ~name m)

(* Encode then decode, so a [t] only ever exists as a decoded body and cannot
   fail to round-trip. *)
let make ~name ~h1 ~h2 ~size ~chunk_size ~chunks ~mtime =
  of_string
    (Chunk_table.encode ~name ~size ~chunk_size ~mtime ~h1 ~h2 ~symlink:None
       ~keys:(List.map chunk_key chunks))

(* A chunkless manifest carrying its target; POSIX size is the target's byte
   length. *)
let make_symlink ~name ~target ~mtime =
  of_string
    (Chunk_table.encode ~name
       ~size:(Int64.of_int (String.length target))
         (* No chunks to group; the domain default keeps the field
            well-formed. *)
       ~chunk_size:Conf.default_chunk_size ~mtime ~h1:(Xxhash.hash_hex target 0)
       ~h2:(Xxhash.hash_hex target 1) ~symlink:(Some target) ~keys:[])
