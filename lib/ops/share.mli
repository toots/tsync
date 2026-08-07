(** Publishing a link to a file or folder.

    A share manifest lives under [shares_prefix], outside every domain root, so
    publishing one changes no domain content: a read-only domain can share what
    it can already read. The token is the manifest's id, and the server rebuilds
    the key from it, so the token alone is what guards the URL. *)

(** Two exceptions rather than one, because they mean different things: nothing
    here can serve a link at all, versus there is nothing at that path to link
    to. Raised internally and mapped to [Error] at the boundary, so a caller
    decides how to report them. *)

(** No configured backend can hold a share manifest. *)
exception Share_unavailable of string

(** There is nothing at that path to link to. *)
exception Share_not_found of string

module Make (C : Conf.S) : sig
  (** Publish a share for [rel], answering its token. [expires] is a Unix
      timestamp; [token] reuses an existing one instead of minting a fresh
      random id, for a caller replacing a link in place. *)
  val create :
    ?token:string ->
    expires:int ->
    rel:string ->
    unit ->
    (string, string) result Lwt.t
end
