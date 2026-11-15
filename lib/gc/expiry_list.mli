(** Expiry lists (spec algorithms/gc.md §4.1): the versions an operator chose to
    expire, one line each, as [tsync versions] prints them. *)

open Tsync_core

type entry = {
  ns : int64;
  size : int option;  (** [None]: the body did not read *)
  path : string;  (** as {!path} spells it *)
}

(** A file's path in the domain, or its name and [" (folder gone)"]. *)
val path : folder:string option -> name:string -> string

(** [<ns>  <date>  <size>  <path>], the line of [tsync versions] too. *)
val line : entry -> string

(** The header, then the entries by path, newest first. *)
val print :
  domain:Domain_name.t -> cutoff:float -> now:float -> entry list -> string

type parsed = {
  number : int;  (** 1-based, in the file *)
  ns : int64;
  folder : string option;  (** [None]: the folder was gone *)
  name : string;
}

type listing = {
  domain : string option;  (** the [# domain:] header *)
  lines : parsed list;
  malformed : (int * string) list;
}

val parse : string -> listing

type resolution = {
  matched : Key.t list;  (** in list order, each once *)
  rejected : (int * string) list;
      (** malformed lines included, by line number *)
  absent : int list;  (** already expired *)
  warnings : (int * string) list;  (** matched, in a renamed folder *)
}

(** Against a listing of version keys; [folder_path] is a folder's current path
    in the domain, [""] for the top. *)
val resolve :
  domain:Domain_name.t ->
  folder_path:(Folder_id.t -> string option) ->
  versions:Key.t list ->
  listing ->
  resolution

module Make (_ : Tsync_remote.Context.S) : sig
  (** Climbed through anchors; [None] for a folder without one. *)
  val folder_path : Folder_id.t -> string option

  (** The folder of a history group [<folder id>/<digest>]. *)
  val group_folder : string -> Folder_id.t option

  val entry : ?folder:string -> ns:int64 -> Manifest.t -> entry

  (** Version keys as entries, and the keys whose body did not read. *)
  val entries : Key.t list -> entry list * Key.t list

  (** Against the domain's version listing. *)
  val resolve : listing -> resolution
end
