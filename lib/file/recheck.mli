(** Domain-wide recheck: walk every manifest sidecar in the local cache and
    verify/repair the corresponding remote chunks and manifest (see
    {!Remote.Make.recheck_cached} and {!Remote.Make.recheck_evicted}). *)

type status =
  | Unreadable  (** sidecar could not be read or parsed; skipped *)
  | Dirty  (** upload pending; skipped *)
  | Checked of Remote.recheck_report

type summary = {
  checked : int;
  repaired : int;
  unrepairable : int;
  skipped : int;
}

(** One human-readable status line for [rel], e.g.
    ["FIXED a/b.bin (1 chunk re-uploaded)"]. *)
val describe : string -> status -> string

module Make (C : Conf.S) : sig
  (** Recheck every file in the domain in sorted order, calling [on_file] with
      each file's domain-relative path and status. Files whose local data is
      present are re-hashed and fully repairable; evicted files are verified
      from their sidecar. Returns [None] when the domain has no local cache. *)
  val run :
    on_file:(rel:string -> status -> unit) -> unit -> summary option Lwt.t
end
