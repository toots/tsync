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

(** The key scheme a caller holding real paths wants. *)
module type INODE_LAYOUT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) :
    Layout.S with type 'a io := 'a io
end

(** The folder id this client already records, if any. *)
module type FOLDER_IDS = sig
  type 'a io

  val lookup_id :
    cache_root:string -> domain_name:string -> Logical_key.t -> string option io
end

module Over
    (Io : Io.S)
    (_ : FOLDER_IDS with type 'a io := 'a Io.t)
    (_ : INODE_LAYOUT with type 'a io := 'a Io.t) : sig
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
