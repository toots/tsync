(** The journal store (spec 03 §2.4–2.5, §3.1): immutable entries under
    [tsync/<d>/journal/] and the cursor, a hint that peers should look. *)

open Tsync_core
open Tsync_store

type t

val create : Domain_name.t -> Store.t -> t

(** Every entry, by key order, with the key it was listed at; a failed listing
    raises. *)
val list_entries : t -> (Entry_key.t * Key.t) list

(** [None] when absent; CORRUPT for a body that violates 03 §2.3. *)
val read_entry : t -> Key.t -> Op.t list option

(** At the canonical key. *)
val entry_exists : t -> Entry_key.t -> bool

val write_entry : t -> Entry_key.t -> Op.t list -> unit
val cursor_read : t -> [ `None | `Key of Entry_key.t | `Unparsed of string ]

(** The watch token of the cursor's current body. *)
val cursor_token : t -> string option

(** Return when the cursor may have changed, driver-paced. *)
val cursor_wait : t -> string option -> unit

(** Arm the debouncer; never writes inline. *)
val note : t -> Entry_key.t -> unit

(** Write now if the interval has passed, else [note]. *)
val bump : t -> Entry_key.t -> unit

(** Write the pending key now; a failure is logged and dropped. *)
val flush : t -> unit
