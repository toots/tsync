external hash_with_seed : string -> int -> int64 = "caml_xxh3_64_with_seed"

type hash_state

external hash_state_create : string -> hash_state = "caml_hash_state_create"
external hash_state_cancel : hash_state -> unit = "caml_hash_state_cancel"
external hash_state_reset : hash_state -> unit = "caml_hash_state_reset"

external hash_state_is_cancelled : hash_state -> bool
  = "caml_hash_state_is_cancelled"

external hash_file_chunks_raw : hash_state -> int -> (int * int64 array) option
  = "caml_hash_file_chunks"

let hash_hex data seed = Printf.sprintf "%016Lx" (hash_with_seed data seed)

let hash_file_chunks state ~chunk_size =
  match hash_file_chunks_raw state chunk_size with
    | None -> None
    | Some (size, raw) ->
        Some
          ( size,
            Array.init
              (Array.length raw / 2)
              (fun i ->
                ( Printf.sprintf "%016Lx" raw.(2 * i),
                  Printf.sprintf "%016Lx" raw.((2 * i) + 1) )) )
