(** A domain's configuration, for a test that needs one rather than a fleet.

    Written out per test, this is twenty-odd lines of which two or three carry
    the test's intent and the rest are the same prefixes derived from the same
    domain name. Everything here has a default, so a test names only what it is
    actually about. *)

(** A domain called [domain] whose keys live under ["tsync/<domain>/"] and whose
    cache and data live under [root]. [store] defaults to a [local] backend at
    [root/store], and [members] to that one store named ["local"].

    [verify_writes:false] is for a fixture whose bodies are not real chunks and
    which a checking store would otherwise file as corrupt, one marker each. *)
val conf :
  ?domain:string ->
  ?client_name:string ->
  ?versioning:bool ->
  ?store:(module Backend.S) ->
  ?members:Backend.member list ->
  ?verify_writes:bool ->
  ?max_uploads:int ->
  ?max_chunk_buffers:int ->
  ?max_downloads:int ->
  ?chunk_size:int ->
  ?cache_chunk_size:int ->
  ?max_cache:int ->
  ?symlink_policy:[ `Keep | `Follow | `Skip ] ->
  ?read_only:bool ->
  ?socket_path:string ->
  ?cache_root:string ->
  ?data_dir:string ->
  root:string ->
  unit ->
  (module Conf.S)

(** The store a bare {!conf} builds, for a test that plants content before
    handing the domain over. *)
val local_store : ?verify_writes:bool -> string -> (module Backend.S)
