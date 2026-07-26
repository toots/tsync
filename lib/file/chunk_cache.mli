(** The local chunk store: backend chunk bodies named by their content key.

    A chunk is present iff its file exists — there is no residency record — and
    any chunk may vanish at any time (the cache cap deletes them), so every read
    treats a miss as ordinary and fetches again. Bodies are shared: the same
    chunk in two files is one file on disk and one download. *)

(** What the store needs from the backend layer. {!Remote.S} satisfies it. *)
module type Fetch = sig
  val get_chunk : chunk_key:string -> string Lwt.t
end

module Make (C : Conf.S) (F : Fetch) : sig
  (** Whether this chunk's body is local. *)
  val exists : string -> bool Lwt.t

  (** Put the body on disk unless already there, atomically. Concurrent callers
      for one key await a single fetch. [force:true] re-fetches regardless, for
      a body believed corrupt. *)
  val ensure : ?force:bool -> chunk_key:string -> unit -> unit Lwt.t

  (** Fill [buf] from the body, starting [chunk_off] bytes into it and fetching
      it if absent. A body that vanishes (or is truncated) under the read is
      fetched again and the read retried once. *)
  val read_into :
    chunk_key:string -> Local_io.buffer -> chunk_off:int -> int Lwt.t

  (** The body if it is already here, without fetching it. *)
  val body_if_local : chunk_key:string -> string option Lwt.t

  (** Drop one body. It is re-fetched on the next read. *)
  val forget : chunk_key:string -> unit Lwt.t

  (** Re-hash every body and delete the ones that do not match their own name,
      returning [(checked, dropped)]. Content addressing makes this the complete
      local-integrity check, and deletion the complete repair. *)
  val verify : unit -> (int * int) Lwt.t

  (** {2 Staged bodies}

      A chunk being written locally has no content key yet — its bytes are still
      changing — so it lives under a uuid until the upload that hashes it
      renames it into place ({!promote}). Staged bodies are unsynced data and
      are never reclaimed by the cap. *)

  (** Path of a staged body, for the upload that reads and hashes it. *)
  val staged_path : string -> string

  (** Create a sparse body of [len] zero bytes. *)
  val stage_empty : uuid:string -> len:int -> unit Lwt.t

  (** Create a body holding a published chunk's bytes, for a write covering only
      part of it (read-modify-write). *)
  val stage_from_chunk : chunk_key:string -> uuid:string -> unit Lwt.t

  val stage_write : uuid:string -> Local_io.buffer -> chunk_off:int -> int Lwt.t

  val stage_read_into :
    uuid:string -> Local_io.buffer -> chunk_off:int -> int Lwt.t

  val stage_truncate : uuid:string -> len:int -> unit Lwt.t
  val stage_forget : uuid:string -> unit Lwt.t

  (** Rename a staged body under the content key its bytes hash to. Idempotent,
      so an interrupted promotion can be replayed. *)
  val promote : uuid:string -> chunk_key:string -> unit Lwt.t

  (** Number of downloads currently in flight. *)
  val in_flight : unit -> int

  (** [(chunks, bytes)] currently held. *)
  val stats : unit -> (int * int) Lwt.t

  (** While the store exceeds [C.max_cache], delete chunk bodies oldest-mtime
      first. No-op when [max_cache] is unset. Needs no notion of what is in use:
      a chunk deleted from under a reader is fetched again. Never touches staged
      data, which lives in a different tree. *)
  val enforce_cap : unit -> unit Lwt.t
end
