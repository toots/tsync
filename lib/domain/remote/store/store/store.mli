(** Manifest-level backend access, keyed by logical keys.

    A logical key becomes a backend key through the {!Layout} scheme, so no
    caller here or above ever constructs one. Everything goes through
    {!Conf.store}, which is what fans a write out and orders a read. Chunk,
    journal and cursor objects are not manifest keys and live in {!File_store}
    and {!Remote}. *)

include module type of struct
  include Store_intf
end

module Over
    (Io : Io.S)
    (_ : Folder_ids.S with type 'a io := 'a Io.t)
    (Batched : BATCHED with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t and type pool = Batched.pool
