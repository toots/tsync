(** Domain-wide recheck, in two independent halves: every manifest sidecar is
    verified against the backend ({!Remote.Make.recheck_from_manifest}), and
    every body in the local chunk store is re-hashed against its own name
    ({!verify_chunk_cache}). *)

type status =
  | Unreadable  (** sidecar could not be read or parsed; skipped *)
  | Staged  (** unsynced local edits; skipped *)
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
      each file's domain-relative path and status. Returns [None] when the
      domain has no local cache. *)
  val run :
    on_file:(rel:string -> status -> unit) -> unit -> summary option Lwt.t

  (** Re-hash every chunk body and delete the ones that do not match their own
      name, returning [(checked, dropped)]. A dropped body is re-downloaded on
      the next read, so this is both the check and the repair for local bit rot.
  *)
  val verify_chunk_cache : unit -> (int * int) Lwt.t
end
