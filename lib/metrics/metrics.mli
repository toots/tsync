(** Record bytes sent to / received from the backend, and chunks hashed. *)
val add_uploaded : int -> unit

val add_downloaded : int -> unit
val add_hashed : int -> unit

(** Cumulative totals since the daemon started. *)
val uploaded : unit -> int

val downloaded : unit -> int
val hashed : unit -> int

(** Recent rate (per second, averaged over a short window). Bytes/s for
    up/download, chunks/s for hashes. *)
val upload_rate : unit -> float

val download_rate : unit -> float
val hash_rate : unit -> float
