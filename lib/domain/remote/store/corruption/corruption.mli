(** Chunks a store found were not what their names say.

    What fails is filed under {!Chunk_layout.corrupted_prefix}, and that object
    {i is} the record, so reading the list is a listing of a prefix every
    backend already serves.

    There is no clearing operation: a marker is removed by whoever re-verifies
    the object, so a chunk nobody fixed cannot be marked clean by a client that
    merely believes it was. *)

include module type of struct
  include Corruption_intf
end

module Over (Io : Io.S) : OVER with type 'a io := 'a Io.t
