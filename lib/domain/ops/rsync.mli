(** What copying one entry comes to, decided before anything is done about it.

    Deciding is separate from acting because the cheap answers are the point: a
    file whose chunks this domain already holds is published, not moved, however
    large it is. *)

(** A local file, as the only thing worth comparing it by. A timestamp says
    nothing about content and a manifest cannot hold one faithfully anyway, so
    identity here is always the bytes. *)
type local =
  | Link of string  (** what a symlink points at, which is its whole content *)
  | Hashed of string array
      (** chunk keys of the bytes on disk, cut the way the manifest they are
          compared against was cut, so index [i] names one span on both sides *)
  | Unhashed
      (** nothing on the other side to compare against, so nothing was read *)

type side = [ `Local | `Domain ]
type source = [ `Missing | `Dir | `File of local | `Key of Manifest.t ]

(** A destination that does not exist is still one side or the other, and which
    one says whether the answer is a manifest publish or a local write. *)
type target =
  [ `Absent of side | `Dir of side | `File of local | `Key of Manifest.t ]

type skip =
  [ `Source_missing
  | `Identical
  | `Target_is_dir
  | `Target_not_a_dir
  | `Not_in_domain  (** neither end is in a domain, which is plain rsync's job *)
  ]

type t =
  | Skip of skip
  | Make_dir of side
  | Rename_in_domain
      (** A move within the domain onto nothing: one journal op, no publish. *)
  | Copy_manifest of Manifest.t
      (** The source's chunks are already in this domain's chunk space, so
          publishing its key list under the destination key is the whole copy.
      *)
  | Upload of [ `Fresh | `Replacing ]
      (** Local to domain, where the store keeps only the chunks it lacks and
          the differing ones are therefore exactly what is sent. *)
  | Assemble of Manifest.t  (** Domain to local, whole file. *)
  | Patch_local of { src : Manifest.t; chunks : int list }
      (** Domain to local, fetching these chunk indices and no others. *)

val decide : move:bool -> src:source -> target -> t

(** A short label for one decision, for a caller reporting a run. *)
val describe : t -> string

(** Whether the source survives the action. *)
val source_disposal : move:bool -> t -> [ `Keep | `Drop ]

(** Captured before the functor parameter of the same name shadows it. *)
type listed = Checkout.listed = {
  key : Logical_key.t;
  size : int;
  mtime : float;
}

(** One end of the copy, named the way the command's caller named it. *)
type endpoint = Local of string | Domain of string

type outcome = Copied of int64 | Skipped of skip | Made_dir | Failed of string

type summary = {
  copied : int;
  skipped : int;
  dirs : int;
  failed : int;
  bytes_moved : int64;
}

module Over
    (Io : Io.S)
    (_ : Fs.S with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (_ : Folder_ids.S with type 'a io := 'a Io.t)
    (_ : Remote.OVER with type 'a io := 'a Io.t)
    (_ : Store.INODE with type 'a io := 'a Io.t)
    (_ : File_store.OVER with type 'a io := 'a Io.t)
    (_ : Manifests.OVER with type 'a io := 'a Io.t)
    (_ : Checkout.OVER with type 'a io := 'a Io.t)
    (_ : Data.OVER with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** Copy every entry under [src] to [dst], deciding per entry what that
        comes to. [move] drops each source once its destination is published,
        and takes the rename where both ends are in one domain. A local file is
        hashed wherever there is a manifest to compare it against, so what is
        skipped is skipped for having the same bytes. *)
    val run :
      ?move:bool ->
      ?dry_run:bool ->
      ?on_entry:(rel:string -> t -> unit) ->
      src:endpoint ->
      dst:endpoint ->
      unit ->
      summary Io.t
  end
end
