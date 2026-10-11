(** A one-off for deployments made before the log: removes from a domain's
    stores and from this client's local state what the journal protocol left
    (journal entries, the folder trash and the folders in it, the WAL, the
    last-sync mark, folder claims), so that every client arrives by state on the
    tree as it stands. To be deleted once every deployment has run it.

    Run it with every client drained on the previous version and stopped. *)

(** The command's exit status. Without [apply] it only reports. It refuses to
    act over unpublished records of the previous version unless [discard].

    [in_sync] is the operator's word that this client had applied the whole
    journal and published everything when it stopped: it then starts at entry 0
    with its mirror as it is, where it would compare it with the whole tree. *)
val run :
  out:(string -> unit) ->
  cancelled:(unit -> bool) ->
  Tsync_domain.Domain.t ->
  apply:bool ->
  discard:bool ->
  in_sync:bool ->
  int
