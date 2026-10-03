(** [tsync mirror] (spec 05 §4.6): copy what one member holds to the others,
    additively. Chunks are compared by name and size, everything else by the
    stores' checksums, and replaced only if unchanged since compared. Chunks go
    before the manifests that name them and the cursor last; the chunk area is
    compared shard by shard, so memory holds one shard's listings at a time. *)

open Tsync_core

type scope = All | Skip_chunks | Path of string

type copied = {
  name : string;  (** the destination member *)
  checked : int;
  copied : int;
  copied_bytes : int;
  changed : int;
      (** keys the destination took from another writer after the comparison
          read them: left as written, for the next run *)
  unguarded : int;
      (** keys written plainly, the destination unable to replace conditionally
      *)
  failed : (string * string) list;  (** key and why the destination refused it *)
}

type report = { source : string; copies : copied list; cancelled : bool }

module Make (_ : Tsync_remote.Context.S) : sig
  (** [source] names a member, else the first in role order. INVALID with fewer
      than two members or an unknown source; REFUSED for [All] or [Path] while a
      collection is open. *)
  val mirror :
    ?narrate:Narrate.t ->
    ?cancelled:(unit -> bool) ->
    ?source:string ->
    scope ->
    report
end
