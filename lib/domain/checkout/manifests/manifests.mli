(** Which manifest describes one file right now, and how to replace it.

    The mirror keyed one file at a time: what the store has published for it,
    what this client has staged over that, and the writing of either. The tree
    it all sits in — listings, directories, renames — is {!Checkout}, which is
    built on this. *)

module type S = Manifests_intf.S

(** The shape a consumer takes: {!S} for whichever domain it is applied to, and
    what stands beside it. *)
module type OVER = Manifests_intf.OVER

module Over
    (Io : Io.S)
    (_ : Cache_layout.FS with type 'a io := 'a Io.t)
    (_ : Staged_manifest.OVER with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t
