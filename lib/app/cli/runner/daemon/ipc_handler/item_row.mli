(** One item as every caller names it: the reference it answers to, its
    container's, and what describes it.

    A listing, a stat and a change all answer with this, so a reader parses one
    shape and the three cannot drift apart. *)

type kind = [ `Dir | `File | `Symlink ]

type t = {
  self : Item_ref.t;
  parent : Item_ref.t;
  name : string;
  kind : kind;
  size : int;
  mtime : float;
  etag : string;
      (** [""] for a file with unsynced edits, which has no published hash. A
          directory's is its own id, constant for the folder's lifetime, so a
          caller watching for change is not told a directory just changed on
          every look. *)
  is_uploaded : bool;
  symlink : string option;
  trashed : bool;
}

(** The wire fields, in the order every reply has spelled them. [trashed] is
    written only when set, so a row for a live item is what it always was. *)
val fields : t -> (string * Yojson.Safe.t) list

val to_json : t -> Yojson.Safe.t

(** The row for a directory whose id the caller already holds.

    A journal op carries the folder's id precisely because the marker it would
    otherwise be read from does not survive the op: a removal destroys it, and a
    rename moves it somewhere a lookup by the old path will not find. Everything
    a directory's row says is derivable from the id and the naming, so nothing
    here has to reach the mirror at all. *)
val dir_with_id :
  self:Item_ref.t -> parent:Item_ref.t -> name:string -> string -> t

module Make (C : Conf_lwt.S) (F : File_ops.S with type 'a io := 'a Lwt.t) : sig
  (** The id of the folder [key] is, [None] for one this client records none
      for. Mints nothing: a read that minted would persist a marker, which is
      how a deleted folder comes back from a stat. *)
  val own_folder_id : Logical_key.t -> string option Lwt.t

  (** The id of the folder [key] sits in. *)
  val parent_folder_id : Logical_key.t -> string option Lwt.t

  (** The reference an item answers to, for a caller holding a key and no
      listing to share a resolved folder with. The kind is read from the mirror,
      a key not carrying one. *)
  val item_ref : Logical_key.t -> string option Lwt.t

  (** The row for one item. [None] when the mirror holds nothing under [key], or
      this client cannot name the folder it sits in. [expect] holds a reference
      to the kind it spells: an [f:] reference must not answer for a folder. *)
  val of_key :
    ?expect:[ `Any | `Dir | `File ] -> Logical_key.t -> t option Lwt.t

  (** The row for a subdirectory of a listing whose container id is already
      resolved, which is why it is passed rather than looked up per entry. *)
  val of_dir : container_id:string -> Logical_key.t -> t option Lwt.t

  (** The row for a file entry of such a listing. Listed objects are manifests,
      so what the listing carries is the manifest's own size and mtime: the
      published manifest gives the logical ones and [h1] as the etag, and a file
      with no clean hash falls back to what the listing had. *)
  val of_listed : container_id:string -> Checkout.listed -> t option Lwt.t
end
