(* Newline-separated because a key is hex and a slash, so nothing needs escaping
   and the function reading it back needs no parser.

   One request per flush rather than one per shard, the collection having
   already pooled its keys to the size both stores cap a bulk delete at. *)
let encode keys = String.concat "\n" keys

let decode body =
  List.filter (fun l -> l <> "") (String.split_on_char '\n' body)

let queue ~put ~chunk_prefix ~run ~name ~keys () =
  put
    ~key:(Chunk_layout.gc_job_key ~chunk_prefix ~run name)
    ~data:(encode keys) ()
