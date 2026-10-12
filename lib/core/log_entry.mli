(** Commands and the log entry (spec 03 §2.3–2.4), and the value of a file key
    as the sync state, the merge and the log see it. *)

(** A file's value: a manifest, a content identity alone (a guard, a
    before-value), or content with no identity yet (an Owed staged edit, an
    unknown before-value), which differs from every value, itself included. *)
type value = Known of Manifest.t | Identity of string | Unknown

(** [<h1>-<h2>]. *)
val identity_of : Manifest.t -> string

val identity : value -> string option
val equal : value -> value -> bool

type command = value Algebra.command

(** Keys as 03 §2.3 writes them: [{"file":[id, leaf]}] or [{"folder":id}],
    merged into the object that carries the key's values. *)
val key_fields : Algebra.key -> (string * Yojson.Safe.t) list

(** [Error] says what is missing or invalid. *)
val key_of_json : Yojson.Safe.t -> (Algebra.key, string) result

val place_to_json : Algebra.place option -> Yojson.Safe.t
val place_of_json : Yojson.Safe.t -> (Algebra.place option, string) result

(** An identity or [null]; INVALID for a value without one. *)
val guard_to_json : value option -> Yojson.Safe.t

val guard_of_json : Yojson.Safe.t -> (value option, string) result

(** A manifest in base64, recorded under [leaf], or [null]; INVALID for a value
    that is not {!Known}. *)
val manifest_to_json : leaf:string -> value option -> Yojson.Safe.t

val manifest_of_json : Yojson.Safe.t -> (value option, string) result

type t = { author : string; projector : string option; commands : command list }

(** The body of an entry, checked to decode back to the same batch; INVALID for
    an empty batch, two commands on one key, or a file whose value after is not
    a manifest. *)
val encode : t -> string

val decode :
  string -> [ `Entry of t | `Later_version of int | `Corrupt of string ]

(** The chunks an entry's manifests name, for the reference gate; an entry of a
    later version or one that does not decode is an error. *)
val chunk_names : Bigstring.t -> (Chunk_key.t list, string) result

(** [MAX_ENTRY_BYTES] and [MAX_ENTRY_COMMANDS] (publication §7). *)
val max_bytes : int

val max_commands : int
