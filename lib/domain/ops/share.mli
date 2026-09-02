(** Publishing a link to a file or folder.

    A share manifest lives under [shares_prefix], outside every domain root, so
    publishing one changes no domain content: a read-only domain can share what
    it can already read. The token is the manifest's id, and the server rebuilds
    the key from it, so the token alone is what guards the URL. *)

(** Both are raised internally and mapped to [Error] at the boundary, so a
    caller decides how to report them. *)

(** No configured backend can hold a share manifest. *)
exception Share_unavailable of string

(** There is nothing at that path to link to. *)
exception Share_not_found of string

module Over
    (Io : Io.S)
    (_ : Folder_ids.S with type 'a io := 'a Io.t)
    (_ : Layout.OVER with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** Publish a share for [rel], answering its token. [expires] is a Unix
        timestamp; [token] reuses an existing one instead of minting a fresh
        random id, for a caller replacing a link in place. *)
    val create :
      ?token:string ->
      expires:int ->
      rel:string ->
      unit ->
      (string, string) result Io.t

    (** Delete every object the share server has assembled and cached, answering
        how many went and how many bytes they held. Published links are
        untouched — a share manifest lives beside the cache subtree, not in it —
        so the next download rebuilds what it needs. *)
    val clear_cache : unit -> (int * int, string) result Io.t
  end
end
