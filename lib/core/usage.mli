(** What this process uses (spec 07 §5.5, the process block): memory split by
    where it lives, the OCaml heap, and CPU time. Anonymous memory is live
    allocation, the OCaml heap plus malloc'd buffers such as bigstrings;
    file-backed memory is the kernel paging mapped files in, reclaimable and not
    the process's to free. *)

type t = {
  resident : int;
  private_ : int;
  swapped : int;
  anonymous : int option;  (** [None] where the system does not say *)
  file_backed : int option;
  heap : int;  (** the OCaml major heap *)
  top_heap : int;
  minor_collections : int;
  major_collections : int;
  cpu_seconds : float;
}

val sample : unit -> t

(** The 07 §5.5 process fields, plus [anonymousBytes] and [fileBackedBytes]. *)
val to_json : t -> Yojson.Safe.t

(** Returns the allocator's free memory to the kernel, after a large operation.
*)
val trim : unit -> unit
