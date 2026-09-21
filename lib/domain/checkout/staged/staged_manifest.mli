(** What this client has changed and not published: one sidecar per file, in a
    tree keyed exactly like the published one, so a staged manifest and the
    published one it shadows sit at matching paths.

    The only copy there is. {!Cache_layout.clear} rebuilds the rest of the
    checkout from the store and leaves this tree alone, which is the whole
    reason it is a store of its own. The bytes these sidecars point at are next
    door in {!Staged_body}. *)

include module type of struct
  include Staged_manifest_intf
end

(** The distinct bodies a slot array names, sorted. Fewer than the slots
    wherever a group shares one. *)
val body_uuids : slot array -> string list

(** The edits either way, for callers that do not care which half. *)
val edits : state -> staged

(** A fresh staged-body id. *)
val new_uuid : unit -> string

(** Where the sidecar for [key] sits, for the synchronous CLI paths that hold no
    functor instance. *)
val sidecar_path :
  cache_root:string -> domain_name:string -> Logical_key.t -> string

module Over
    (Io : Io.S)
    (_ : Cache_layout.FS with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t
