(** This client's intent log: what it set out to do, and how far it got.

    Entirely local. The shared journal on the backend is {!File_store}'s, and
    this module never sees a backend key — which is what lets the same recovery
    run against any store.

    The record is the source of truth for a unit of work, not the staged tree.
    Recovery used to be driven from the staged tree, minting a fresh entry key
    on every replay and orphaning the record it should have finished; one domain
    accumulated 295 orphans that way, all reported as one opaque number. *)

(** There is no "committed" state: the record is deleted the moment the entry is
    published, and a crash in that window leaves [Executed], which reconcile
    resolves by asking the backend whether the entry is there. Writing a state
    only to delete it would be a disk write per upload buying nothing. *)
type state =
  | Intent  (** Recorded. Nothing has happened yet. *)
  | Prepared  (** The data is staged locally; the upload is owed. *)
  | Executed  (** The bytes are on the backend; the entry is not published. *)

type record = {
  key : Journal.Entry_key.t;
  ops : Journal.op list;
  state : state;
  attempts : int;
  last_error : (Backend.kind * string) option;
      (** Why it last failed, so a stuck record can say so instead of being
          counted. *)
}

val string_of_state : state -> string

module Make (C : Conf.S) : sig
  (** Write the intent. The caller mints the key and keeps it: every later call
      names the same unit of work. *)
  val record : Journal.Entry_key.t -> Journal.op list -> unit Lwt.t

  val advance : Journal.Entry_key.t -> state -> unit Lwt.t

  (** Count the attempt and remember why. Does not change the state: a failure
      leaves the work where it was. *)
  val note_failure : Journal.Entry_key.t -> Backend.kind -> string -> unit Lwt.t

  (** The work is done or abandoned; drop the record. *)
  val complete : Journal.Entry_key.t -> unit Lwt.t

  (** This client's records, in {!Journal.Entry_key.compare} order — the order
      the ops must be replayed in. Other clients' records, if a shared data
      directory ever holds any, are left alone. *)
  val list : unit -> record list Lwt.t
end
