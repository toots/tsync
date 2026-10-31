(** The apply (cloud-files §10): brings the domain into the sync root, folder by
    folder. The host creates it once the root is connected and {!start}s it; the
    changed hook {!wake}s it, a listing callback and a take that landed aside
    {!schedule} a folder, and reannounce makes its anchor stale. Its anchor and
    pending folders survive restarts in the state file. *)

type t

val create :
  engine:(module Tsync_sync.Engine.S) ->
  handler:Tsync_owner.Handler.t ->
  root:string ->
  take:Take.t ->
  unshown:Unshown.t ->
  state_file:string ->
  unit ->
  t

(** Applies the folder this reference names at the next round. *)
val schedule : t -> string -> unit

(** A round after [APPLY_DEBOUNCE]. *)
val wake : t -> unit

(** The next round reads the domain from the start: every populated folder is
    applied (§10.3, [stale]). *)
val restart_anchor : t -> unit

val start : t -> unit

(** Folders whose apply has not finished. *)
val pending : t -> int
