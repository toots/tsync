(** What an import would bring in (spec 05 §4.3 step 2): a walk of the source
    directory, in the sort order of full paths, applying [only], [exclude] and
    the symlink policy. Nothing of the domain is read. *)

type entry =
  | Folder of string  (** its domain-relative path *)
  | File of {
      rel : string;
      path : string;
      size : int;
      times : Tsync_core.Fs.times option;
    }  (** [times] overrides the source's own *)
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
  uncommitted : int;
      (** changes made and not committed when the run was interrupted *)
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

(** A plan from a map file of lines [LOCAL_PATH TAB DOMAIN_PATH], optionally
    followed by [TAB MTIME_NS TAB CREATED_NS], a relative [LOCAL_PATH] taken
    from [base]. Every folder above a domain path is planned. A malformed line,
    an invalid or reserved domain path, a duplicate, or a domain path that is
    also a planned folder raises INVALID. An unreadable [LOCAL_PATH] is planned
    with 0 bytes and fails at upload. *)
val of_map : base:string -> string -> plan
