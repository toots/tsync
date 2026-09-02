(* Newline-separated because a key is hex and a slash, so nothing needs escaping
   and the function reading it back needs no parser.

   One request per flush rather than one per shard, the collection having
   already pooled its keys to the size both stores cap a bulk delete at. *)
let encode keys = String.concat "\n" (List.map Stored_key.to_string keys)

let decode body =
  List.filter_map
    (fun l -> if l = "" then None else Some (Stored_key.listed l))
    (String.split_on_char '\n' body)

let queue ~put ~chunk_prefix ~run ~name ~keys () =
  let module L = Chunk_layout.Make (struct
    let chunk_prefix = chunk_prefix
  end) in
  put ~key:(L.gc_job_key ~run name) ~data:(encode keys) ()
