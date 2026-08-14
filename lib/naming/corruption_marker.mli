(** What a corruption marker carries beyond existing.

    The key is the finding — see {!Chunk_layout.marker_key} — so everything here
    is for the report an operator reads next, and every field is optional: a
    marker written by a newer build, or truncated by a crash, is still a marker.
*)

type t = {
  computed : string option;  (** what the body hashed to instead *)
  size : int option;  (** what the bad body measured *)
  at : float option;  (** when it was found *)
  reason : string option;
      (** What was wrong, when the key alone does not say. A body that hashed to
          something else needs no explanation — {!computed} is the whole of it —
          but a chunk the store would not read has no hash to record, and on a
          failing disk that is what bit rot looks like: [EIO], not wrong bytes.
      *)
}

val to_string : t -> string

(** Never raises. An unparseable body reads as a marker carrying nothing rather
    than as no marker: the object's existence is the finding, and discarding it
    would report a corrupt chunk as healthy. *)
val of_string : string -> t
