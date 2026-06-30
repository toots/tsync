exception Cancelled

val upload :
  S3_client.t ->
  key:string ->
  src_path:string ->
  mtime:float ->
  ?cancel:bool Atomic.t ->
  chunk_prefix:string ->
  unit ->
  Manifest.state

(** Download [key] to [dst_path]. Returns [Some state] if the object was a
    chunked manifest, [None] if it was a plain object (backward compat). *)
val download :
  S3_client.t ->
  key:string ->
  dst_path:string ->
  chunk_prefix:string ->
  Manifest.state option
