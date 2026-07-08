val chunk_size : int

type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

type t = {
  v : int;
  size : int64;
  chunk_size : int;
  chunks : chunk_entry list;
  h1 : string;
  h2 : string;
  mtime : float;
  symlink : string option;
}

type state = [ `Dirty | `Clean of t ]

val chunk_key : chunk_entry -> string

val make :
  size:int64 ->
  chunk_size:int ->
  chunks:chunk_entry list ->
  mtime:float ->
  state

(** A chunkless manifest representing a symlink to [target]. *)
val make_symlink : target:string -> mtime:float -> state

val of_string : string -> state
val to_string : state -> string
