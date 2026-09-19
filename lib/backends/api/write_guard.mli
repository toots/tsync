(** May a member that is not the main be written right now?

    A replica is a copy of what the main holds. Written while the main is
    offline it holds something nobody can check against the source of truth, and
    a reader then finds it there. A domain's own writes cannot do this, the
    composite telling a replica only of what a main has taken; every write that
    names a member outright asks here first, and nothing else decides. *)

(** The half that asks nothing of anybody, for a caller with no clock. *)
module State (Io : Io.S) : sig
  module type Store = Backend.S with type 'a io := 'a Io.t

  (** What this process knows already, at no round trip. A domain with no main
      has no source of truth to fall behind and is [`Ok]: that is what a
      read-only domain is. *)
  val state : (module Store) Backend.member list -> [ `Ok | `Offline of string ]
end

module Over (Io : Io.S) (_ : Clock.S with type 'a io := 'a Io.t) : sig
  include module type of State (Io)

  type answer = { seconds : float; cursor : Bigstring.t option }

  (** Whether a store is there: one small object at a known key, any answer to
      which, a miss included, is a yes. Bounded by {!Health.probe_timeout}, its
      retries included, a ladder being right for work that must land and wrong
      for a question the first round trip answers. *)
  val probe :
    (module Store) -> cursor_key:Stored_key.t -> (answer, string) result Io.t

  (** Before writing to the member given. A main may always be written, which is
      how one is refilled from a copy; for any other this is {!state}, having
      first gone and looked at any main this process has not heard from, a
      command that has just started knowing nothing. Fails, transiently, with
      [what] was refused and why. *)
  val ensure :
    members:(module Store) Backend.member list ->
    cursor_key:Stored_key.t ->
    what:string ->
    (module Store) Backend.member ->
    unit Io.t

  (** {!ensure} for one domain, which a {!Conf.S} is. *)
  module For (_ : sig
    val members : (module Store) Backend.member list
    val cursor_key : Stored_key.t
  end) : sig
    val ensure : what:string -> (module Store) Backend.member -> unit Io.t
  end
end
