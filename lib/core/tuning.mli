(** The advanced settings of a domain's cycle (spec 05 §2.1, publication §7), in
    seconds and counts. *)

type t = {
  batch_delay : float;
  project_width : int;
  max_entry_commands : int;
  project_lease : float;
  project_quarantine : float;
  project_settle : float;
}

(** The application's defaults. *)
val default : t
