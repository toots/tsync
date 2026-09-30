(** The grammar of every name and key (spec 01 §2), and item references. *)

(** {1 Store keys and prefixes (§2.1)} *)

val valid_key : string -> bool

(** A key followed by exactly one [/], or empty. *)
val valid_prefix : string -> bool

(** Raise INVALID for a string outside the grammar. *)
val check_key : ?op:string -> string -> unit

val check_prefix : ?op:string -> string -> unit

(** {1 Domain names (§2.2)} *)

val reserved_roots : string list

(** Why a name is refused; [local_store] also refuses reserved names in any
    ASCII case, for a store that may fold case. *)
val domain_name_error : ?local_store:bool -> string -> string option

val valid_domain_name : ?local_store:bool -> string -> bool

(** {1 Leaves and paths (§2.3)} *)

val valid_leaf : string -> bool
val valid_path : string -> bool

(** Strip one leading and one trailing [/] from a user path, then validate it.
*)
val user_path : string -> string

val leaf_of : string -> string
val parent_of : string -> string
val join : string -> string -> string

(** [p] is [dir] or lies beneath it. *)
val is_under : dir:string -> string -> bool

(** {1 Folder ids (§2.5)} *)

val root_id : string
val trash_id : string
val valid_folder_id : string -> bool

(** {1 Chunk keys and shards (§3.2, §3.6)} *)

(** Exactly 33 bytes of lowercase dual hex; a test of what a key is. *)
val is_chunk_key : string -> bool

(** The first three characters, or [_] for a shorter key. *)
val shard : string -> string

val valid_shard : string -> bool

(** {1 Item references (§2.7)} *)

type item_ref = Root | Dir of string | File of string * string

(** Total: every string is a reference or malformed; [d:.tsync-root] is {!Root}.
*)
val parse_ref : string -> (item_ref, unit) result

val ref_to_string : item_ref -> string

(** The reference of a folder id, {!Root} for the root id. *)
val dir_ref : string -> item_ref

(** {1 Local names (§2.8, §2.9)} *)

val name_max_local : int

(** Whether a leaf is filed under its own name in a local mirror. *)
val storable : string -> bool

(** The local name of a leaf: itself, or [.tsync-esc-<hex16>]. *)
val escape : string -> string

val escape_path : string -> string

(** A leaf a mirror listing skips: [.tsync-] and not an escape handle. *)
val is_internal_local : string -> bool

(** [.tsync-tmp-] prefix and [.tmp] suffix, both required. *)
val is_temp_name : string -> bool

(** The owning pid of a [.tsync-tmp-<pid>-<seq>.tmp] name. *)
val temp_owner : string -> int option

(** A fresh [.tsync-tmp-<pid>-<seq>.tmp] name. *)
val temp_name : unit -> string
