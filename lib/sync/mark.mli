(** The last-sync mark (spec 03 §2.6): [<data_dir>/last-sync-<domain>]. *)

open Tsync_core

(** Absent or unparseable (reported) is no mark; any other failure raises. *)
val read : data_dir:string -> Domain_name.t -> Entry_key.t option

(** Durable replace; callers only ever move it forward. *)
val write : data_dir:string -> Domain_name.t -> Entry_key.t -> unit
