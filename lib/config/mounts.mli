(** Mount discovery (spec frontends/linux-desktop.md §2, §3): where a domain is
    asked to be mounted, and which configured domains the kernel mount table
    lists as mounted now. *)

(** The [mountPoint] of the domain's [fuse] frontend, else
    [$HOME/tsync/<domain>]; [None] without a [fuse] frontend. *)
val configured : Config.domain -> string option

(** A mount point as the mount table writes it, decoded (§3.2). *)
val decode : string -> string

(** [(canonical mount point, owner socket)] for every configured domain mounted
    now, read from the config and from [table] (the kernel's, by default) at
    each call. Total: any failure is the empty list. It connects to nothing. *)
val mount_points : ?table:string -> unit -> (string * string) list
