(** What an import would bring in (spec 05 §4.3 step 2): a walk of the source
    directory, in the sort order of full paths, applying [only], [exclude] and
    the symlink policy. Nothing of the domain is read. *)

type entry =
  | Folder of string  (** its domain-relative path *)
  | File of { rel : string; path : string; size : int }
  | Link of { rel : string; path : string; target : string; size : int }
      (** [size] as the policy plans it: 0 to skip, the target's length to keep,
          the target's size to follow *)

(** What became of one planned file or link. *)
type outcome =
  | Imported of int
  | Skipped_exists
  | Skipped_symlink
  | Failed of string

type report = {
  imported : int;
  bytes : int;  (** of what was imported *)
  skipped : int;  (** already in the domain *)
  skipped_symlinks : int;
  failed : (string * string) list;  (** path and reason *)
  cancelled : bool;  (** what was left is not counted *)
}

type plan = {
  entries : entry list;  (** folders before what they hold *)
  files : int;  (** files and kept links *)
  bytes : int;
  unreadable : string list;  (** directories that could not be listed *)
}

(** [src] is made absolute and resolved first. *)
val plan :
  ?only:string list ->
  ?exclude:string list ->
  symlinks:[ `Keep | `Follow | `Skip ] ->
  string ->
  plan
