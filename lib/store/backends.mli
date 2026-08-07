(** The configured backend list: which one reads, and how far a write goes. *)

module Make (C : Conf.S) : sig
  (** The backend every read goes to — the head of [C.backends]. Raises when
      none is configured, which is a broken config, not a runtime condition. *)
  val primary : unit -> (module Backend.S)

  (** Run [f] against every backend in order. Sequential: a write lands on the
      primary before any replica. *)
  val all : ((module Backend.S) -> unit Lwt.t) -> unit Lwt.t

  val put : key:string -> data:string -> unit Lwt.t
  val delete : key:string -> unit Lwt.t

  (** Bulk delete on every backend; a no-op for an empty list. *)
  val delete_many : string list -> unit Lwt.t

  val copy : src_key:string -> dst_key:string -> unit Lwt.t
end
