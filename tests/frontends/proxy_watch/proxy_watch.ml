(* A proxy holding a request instead of answering it at once.

   Two things decide whether this is worth doing, and both are counted rather
   than timed. A client that arrives already behind must be answered
   immediately — holding through a change that has happened is the one failure
   this design cannot tolerate, and it is invisible unless something bumps the
   cursor before the request lands. And however many clients wait on a key, the
   store must be asked about it a fixed number of times: without that a proxy
   costs its store exactly what the clients cost it today, and only the link
   between them gets quieter. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "proxy-watch"
let cursor = Stored_key.listed "tsync/watchdom/cursor"
let reads = ref 0

(* The store's [watch] parks on this; the test releases it to make the frontend's
   loop take exactly one turn. *)
let released = Lwt_condition.create ()
let release () = Lwt_condition.broadcast released ()

(* Counts what the frontend asks of its store, which is the figure the fan-in
   claim is about. [watch] parks until the test releases it, so the loop above
   cycles exactly when this says and the counts below are exact rather than a
   function of how fast this machine got round to it. *)
module Store : Backend_lwt.Store = struct
  let objects : (Stored_key.t, Bigstring.t) Hashtbl.t = Hashtbl.create 4

  let put ~key ~data () =
    Hashtbl.replace objects key data;
    Lwt.return_unit

  let get_opt ~key () =
    if key = cursor then incr reads;
    Lwt.return (Hashtbl.find_opt objects key)

  let get_range ~key ~offset ~length () =
    Lwt.return
      (Option.map
         (Doubles.range_of ~offset ~length)
         (Hashtbl.find_opt objects key))

  let get ~key () =
    match Hashtbl.find_opt objects key with
      | Some d -> Lwt.return d
      | None -> Lwt.fail (Backend.Backend_error "no such key")

  let put_if_absent ~key ~data () =
    match Hashtbl.find_opt objects key with
      | Some held -> Lwt.return held
      | None ->
          let* () = put ~key ~data () in
          Lwt.return data

  let head_opt ~key () =
    Lwt.return
      (Option.map
         (fun d ->
           {
             Backend.key;
             size = Bigstring.length d;
             last_modified = 0.;
             etag = None;
           })
         (Hashtbl.find_opt objects key))

  let delete ~key () =
    Hashtbl.remove objects key;
    Lwt.return_unit

  let delete_multi keys =
    List.iter (Hashtbl.remove objects) keys;
    Lwt.return_unit

  let copy ~src_key:_ ~dst_key:_ () = Lwt.return_unit
  let list_prefix ?max_keys:_ ~prefix:_ () = Lwt.return_nil
  let watch ~key:_ ~last_seen:_ () = Lwt_condition.wait released
  let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

  let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
    Lwt.return `Unsupported

  let get_many = None
  let list_many = None
  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
  let fast_read = false
  let local_path = None
end

let route =
  {
    Http_proxy_frontend.domain_root = "tsync/watchdom/";
    shares_prefix = "tsync/shares/";
    secret = "s";
    read_only = false;
    chunk_size = None;
    store = (module Store : Backend_lwt.Store);
    serve_share = None;
    peers = [];
    domain_name = "watchdom";
    traffic = Metrics.traffic ();
    self_frontend = `Assoc [];
    diagnose =
      (fun ~totals:_ ~exact:_ ~reload:_ ~frontends:_ -> Lwt.return (`Assoc []));
  }

let set_cursor body = Store.put ~key:cursor ~data:(Bigstring.of_string body) ()
let token body = Backend.Watch_token.of_wire body

let watch_op ?last_seen wait =
  Http_proxy_frontend.Watch { key = cursor; wait; last_seen }

let run op =
  let* resp, _ = Http_proxy_frontend.exec route op ~body:Bigstring.empty in
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
  let watched =
    Cohttp.Header.get (Cohttp.Response.headers resp) "x-tsync-watched" <> None
  in
  Lwt.return (status, watched)

let () =
  Lwt_main.run
    (case "a request parses as a watch only when it asks to wait";
     let uri s = Uri.of_string s in
     let key = Http_proxy.Wire.encode_key (Stored_key.to_string cursor) in
     check "a plain get is still a get"
       (Http_proxy_frontend.parse_op `GET (uri ("/o/" ^ key)) Bigstring.empty
       = Http_proxy_frontend.Get cursor);
     let parsed =
       Http_proxy_frontend.parse_op `GET
         (uri ("/o/" ^ key ^ "?wait=5&last_seen=abc"))
         Bigstring.empty
     in
     check "one that asks to wait carries the deadline and the token"
       (parsed = watch_op ~last_seen:(token "abc") 5.);
     check "a wait longer than this end allows is cut down to it"
       (Http_proxy_frontend.parse_op `GET
          (uri ("/o/" ^ key ^ "?wait=6000"))
          Bigstring.empty
       = watch_op 30.);
     (* A held request that took a data slot would starve the reads and writes
        it is holding alongside. *)
     check "holding costs no storage slot"
       (Http_proxy_frontend.data_kind (watch_op 5.) = `Meta);
     check "and it is still authorised against its own key"
       (Http_proxy_frontend.op_keys (watch_op 5.)
       = [Stored_key.to_string cursor]);

     case "a client that is already behind is answered, never held";
     let* () = set_cursor "0000000000100-peer" in
     let* status, (_ : bool) = run (watch_op 30.) in
     check "a client with no token at all is answered" (status = 200);
     (* The cursor moves while this end's own watch is parked, so what it
        remembers is now behind what it holds. A waiter arriving here is the
        race: comparing against the remembered token would hold it through a
        change that has already happened. *)
     let* () = set_cursor "0000000000200-peer" in
     let before = !reads in
     let* status, watched =
       run (watch_op ~last_seen:(token "0000000000100-peer") 30.)
     in
     check "answered at once rather than held to the deadline" (status = 200);
     check "and it says this end understood the wait" watched;
     check "one read to decide it" (!reads - before = 1);

     case "a client that is up to date is held until the deadline";
     let before = !reads in
     let* status, watched =
       run (watch_op ~last_seen:(token "0000000000200-peer") 0.3)
     in
     check "no content, the deadline having passed" (status = 204);
     check "still marked as understood" watched;
     check "and the store was not asked again while it was held"
       (!reads - before = 1);

     case "many waiters on one key cost the store one read per change";
     let waiters = 8 in
     let before = !reads in
     let held =
       List.init waiters (fun _ ->
           run (watch_op ~last_seen:(token "0000000000200-peer") 30.))
     in
     let* () = Lwt_unix.sleep 0.1 in
     let* () = set_cursor "0000000000300-peer" in
     release ();
     let* answers = Lwt.all held in
     check "every waiter was answered"
       (List.for_all (fun (status, _) -> status = 200) answers);
     let spent = !reads - before in
     step "waiters: %d, store reads: %d" waiters spent;
     (* One each on arrival, which is what closes the race, and one for the
        change however many were waiting on it. A second term that counted the
        waiters would be the fan-in gone. *)
     check "one read per arrival, and one for the change" (spent = waiters + 1);
     Lwt.return_unit);
  Scratch.cleanup root
