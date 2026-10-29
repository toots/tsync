(** Process ids as other processes see them, for the holder records, leases, job
    reports and temporary names they read back. *)

(** This process's id: [getpid], or on Windows [GetCurrentProcessId], since
    [Unix.getpid] there answers a handle meaningful only to this process. *)
val self : unit -> int

(** Whether a process with this id runs. *)
val alive : int -> bool
