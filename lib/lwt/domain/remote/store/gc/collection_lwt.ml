(* The TTL on whether a run is open is per application, deliberately: see
   {!Collection.Over.Make}. *)
include Collection
include Collection.Over (Io_lwt.Core) (Io_lwt.Retry) (Io_lwt.Fs)
