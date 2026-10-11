(** The log of a domain on its main (spec 03 §3.1): entries read by number and
    created if absent, the tree head, takeovers, the void object and the cursor
    with its debouncer. Every request is the store's; nothing here decides when
    to fetch or push. *)

open Tsync_core
open Tsync_store

type t

val create : Domain_name.t -> Store.t -> t

(** What an entry reads as: a voided entry is one that does not decode and whose
    void object exists (publication §4.3). *)
type read =
  | Entry of Log_entry.t
  | Void
  | Later_version of int
  | Undecodable of string

type entry = { n : int; bytes : string; read : read }

(** The batch an entry holds; none for one that cannot be followed. *)
val commands : entry -> Log_entry.command list option

(** The last command the entries hold on each key they name, in key order: what
    they make of the tree. *)
val last_commands : entry list -> Log_entry.command list

val read_entry : t -> int -> entry option

(** The entries from [from] on, up to the first absent one. *)
val read_entries : t -> int -> entry list

(** Through the reference gate: fails with "missing chunks" on a collectable
    main that lacks one. *)
val create_entry : t -> int -> string -> [ `Won | `Held ]

(** Absent reads as 0; CORRUPT for a body that does not parse. *)
val tree_head : t -> int

(** Written only when the head read back is lower. *)
val raise_tree_head : t -> int -> unit

(** The highest takeover generation of an entry and its holder; 0 and none when
    there is no takeover. *)
val takeover : t -> int -> int * string option

val takeover_create :
  t -> int -> generation:int -> client:string -> [ `Won | `Held of string ]

val void_create : t -> int -> client:string -> [ `Won | `Held of string ]
val cursor_token : t -> string option

(** Returns when the cursor may have changed, bounded by the driver. *)
val cursor_wait : t -> string option -> unit

(** Never writes inline: arms the debouncer. *)
val cursor_note : t -> int -> unit

(** Writes the pending number; a failure is logged and dropped. *)
val cursor_flush : t -> unit

val cursor_interval : float

(** [LOG_RETENTION] (publication §7). *)
val retention : float
