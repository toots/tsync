open Lwt.Syntax

(* Cohttp already pools and redials over its Unix net; deriving either again
   here would be a second spelling of the same two lines. *)
module Pool = struct
  type t = Cohttp_lwt_unix.Connection_cache.t

  exception Redial = Cohttp_lwt_unix.Connection.Retry

  let create ~keep ~parallel () =
    Cohttp_lwt_unix.Connection_cache.create ~keep ~parallel ()

  let call t ~headers ~body meth uri =
    let* resp, rbody =
      Cohttp_lwt_unix.Connection_cache.call t
        ~headers
          (* [`Passthrough]: sent out of the chunk's own bytes rather than a copy,
           which is what a bigstring body is for. The retry above only reads
           them again. *)
        ~body:(Cohttp_lwt.Body.of_bigstring (`Passthrough body))
        meth uri
    in
    let+ rbody = Cohttp_lwt.Body.to_bigstring rbody in
    (resp, rbody)
end

include Http_client
include Http_client.Make (Io_lwt.Core) (Io_lwt.Clock) (Retry_lwt) (Pool)
