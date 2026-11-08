(** The folder index (spec 02 §2.10, binary [tsyncidx1]): a cache of a
    namespace's child bodies, each with the entity tag its listing reported, so
    a folder read costs one listing and one read. *)

(** Full stored key, entity tag, body. *)
type entry = { key : string; etag : string; body : Tsync_core.Bigstring.t }

(** One buffer of exactly the encoded size. *)
val encode : entry list -> Tsync_core.Bigstring.t

(** Any parse error means no index. Bodies are views of the index, so a mapped
    index is never copied whole. *)
val decode : Tsync_core.Bigstring.t -> entry list option

(** [index_max_bytes]: an index listed larger is not read. *)
val max_bytes : int

(** [index_max_children]. *)
val max_children : int
