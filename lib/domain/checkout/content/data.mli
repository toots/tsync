(** File content as bytes, read per chunk out of {!Chunk_cache}.

    A file is never assembled: a read maps its byte range onto the chunks
    backing it, fetching only the ones that are absent. *)

module type S = Data_intf.S

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = Data_intf.OVER

module Over
    (Io : Io.S)
    (Fs : Cache_layout.FS with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t and type fd = Fs.fd)
    (_ : Lock.S with type 'a io := 'a Io.t)
    (_ : Bounded.S with type 'a io := 'a Io.t)
    (_ : Clock.S with type 'a io := 'a Io.t)
    (_ : Manifests.OVER with type 'a io := 'a Io.t) : sig
  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (R : Remote.S with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t
end
