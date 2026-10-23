(** The vault's auto-lock policy (vault §6.2), as a domain configures it and as
    its main states it (05 §2.1 rule 7): [idle_minutes], no use of K for that
    long; [on_screen_lock], the session locks or the machine sleeps;
    [max_hours], that long since the unlock. *)
type t = {
  idle_minutes : int option;
  on_screen_lock : bool;
  max_hours : int option;
}

(** No trigger. *)
val none : t

val is_none : t -> bool

(** The smaller of each limit, and [on_screen_lock] when either sets it. *)
val strictest : t -> t -> t

val to_json : t -> Yojson.Safe.t

(** The members of 05 §2.1 within their ranges; unknown members are dropped.
    [Error] names the member at fault. *)
val of_json : Yojson.Safe.t -> (t, string) result
