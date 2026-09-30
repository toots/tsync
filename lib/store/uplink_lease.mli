(** What lessees and the governor owner exchange (spec
    algorithms/uplink-governor.md §3, §4.5): per-link reports, the max-min fair
    split of a law's rate, and the renewal's wire shapes. Pure. *)

type report = {
  in_flight : int;
  completed : float;  (** bytes since the last report *)
  timeouts : int;  (** since the last report *)
  waiting : int;
  held_back : bool;
  probes : (string * float) list;  (** store name, delay in seconds *)
}

val idle : report

(** [waiting > 0 ∨ held_back]. *)
val wants : report -> bool

(** Grants in the order of [rows], adding up to [total]. *)
val split :
  total:float -> min_rate:float -> interval:float -> report list -> float list

(** The link an old flat report names. *)
val default_link : string

type request = {
  pid : int;
  links : (string * report) list;
  flat : bool;  (** the older single-link shape, answered with [rate] too *)
}

val request_to_json : pid:int -> (string * report) list -> Yojson.Safe.t
val request_of_json : Yojson.Safe.t -> request option

type grant = { rate : float; limit : string }

val answer_to_json :
  interval:float -> flat:bool -> (string * grant) list -> Yojson.Safe.t

(** [None] is a refusal: an answer without per-link grants. *)
val answer_of_json : Yojson.Safe.t -> (float * (string * float) list) option
