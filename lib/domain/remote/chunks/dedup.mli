(** Whether a chunk is already stored, and so need not be sent again.

    Content addressing is what makes this safe to ask at all: a key is the hash
    of the bytes, so a store holding that key holds these bytes. What the answer
    costs is a round trip, which a per-session memo of keys already placed is
    here to save.

    {b The order the three sources are consulted in is the policy, not an
       optimisation}, which is why they are answered together rather than by
    whoever happens to be asking. *)

type t

(** [max_known] caps the memo. Reaching it clears the memo wholesale rather than
    evicting: a session is a command, and one running for days over a terabyte
    holds an entry per distinct chunk with nothing to retire it. Overflowing
    costs a round trip per chunk again, which is what the memo was saving.

    Asked when a key is remembered rather than read once here, so a caller that
    settles the cap after building this — a test, which cannot upload a terabyte
    — still has it obeyed. *)
val create : ?max_known:(unit -> int) -> unit -> t

(** Record that the store holds [key], so {!known} answers without a round trip
    for the rest of the session. *)
val remember : t -> string -> unit

(** How many keys the memo holds, for a report on what a session has spared
    itself. *)
val count : t -> int

module Over (Io : Io.S) : sig
  (** Whether [key] may be taken as already stored.

      [corrupt] says the store filed this key as not holding what its name says.
      Such a key reads as absent whatever the memo or the store answer, and
      neither is consulted. That ordering is what closes the loop: a chunk this
      session placed is in the memo, and a marker says exactly that what it
      placed is not what landed. Asking the store would not help either — a
      corrupt chunk is the right size and so present. Reporting it stored would
      leave the marker with nothing to clear it and, because dedup is what makes
      a chunk shared, hand the bad bytes to every later file containing it.

      [present] asks the store, and is reached only for a key that is neither
      corrupt nor remembered. *)
  val known :
    t ->
    corrupt:(string -> bool Io.t) ->
    present:(string -> bool Io.t) ->
    string ->
    bool Io.t
end
