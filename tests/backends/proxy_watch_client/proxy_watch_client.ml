(* What a client does with a peer that does not hold the request.

   The wait is asked for in a query parameter, which a peer of an older version
   reads as no parameter at all and answers at once. The caller above is a loop
   whose whole pacing is this call, so an answer that costs no time is a spin —
   and it looks exactly like a peer legitimately reporting a change. The header
   is how the two are told apart, and the floor is what happens when it is
   missing. *)

open Lwt.Syntax
open Check

let asked : Uri.t list ref = ref []
let answer_header : (string * string) list ref = ref []

(* Answers whatever the test has set, recording what it was asked, so the query
   the driver builds is asserted rather than assumed. *)
module Fake_http = struct
  type t = unit

  let create ~name:_ ~timeout:_ ~classify:_ () = ()

  let respond uri =
    asked := uri :: !asked;
    Lwt.return
      ( Cohttp.Response.make ~status:`OK
          ~headers:(Cohttp.Header.of_list !answer_header)
          (),
        Bigstring.empty )

  let call () ~headers:_ ~meth:_ ?body:_ uri = respond uri
  let call_retry () ~headers:_ ~meth:_ ?body:_ (_ : string) uri = respond uri

  let call_text () ~headers:_ ~meth:_ ?body:_ (_ : string) uri =
    let+ resp, _ = respond uri in
    (resp, "")
end

module Driver = Http_proxy_backend.Over (Io_lwt.Core) (Fake_http) (Io_lwt.Clock)

module B =
  (val Driver.make ~url:"https://nas.example:8443" ~secret:"s" : Driver.Store)

let cursor = Stored_key.listed "tsync/watchdom/cursor"

let timed f =
  let started = Unix.gettimeofday () in
  let+ () = f () in
  Unix.gettimeofday () -. started

(* A classification, not the figure: the floor is seconds and an honoured wait
   returns in microseconds, so no amount of load moves one into the other. *)
let promptly seconds = seconds < 1.0

let query name =
  match !asked with uri :: _ -> Uri.get_query_param uri name | [] -> None

let () =
  Lwt_main.run
    (case "the wait and the token are what the peer is asked for";
     answer_header := [("x-tsync-watched", "1")];
     let* (_ : float) =
       timed (fun () ->
           B.watch ~key:cursor
             ~last_seen:
               (Some (Backend.Watch_token.of_wire "0000000000100-peer"))
             ())
     in
     check "the request says how long the peer may hold it"
       (query "wait" = Some "30");
     check "and what this client last had"
       (query "last_seen" = Some "0000000000100-peer");

     case "a peer that says it understood is taken at its word";
     let* seconds = timed (fun () -> B.watch ~key:cursor ~last_seen:None ()) in
     check "the answer is passed straight up, having been waited for"
       (promptly seconds);
     check "a client that has nothing to compare sends no token"
       (query "last_seen" = None);

     case "a peer too old to know the parameter is paced from this end";
     answer_header := [];
     let* seconds = timed (fun () -> B.watch ~key:cursor ~last_seen:None ()) in
     (* Without this the caller above spins as fast as the link allows. *)
     check "an answer that cost no time is floored before returning"
       (not (promptly seconds));
     Lwt.return_unit)
