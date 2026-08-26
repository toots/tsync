(* A batch must not queue behind itself.

   {!Backend_lwt.Batched} takes a slot for each request it makes, and a domain's
   stores are presented as one {!Backend.S}: a batch asked of the composite that
   took a second slot for the member it forwarded to held one while waiting for
   the other, and enough callers at once left every slot held by something
   waiting for a slot.

   The default pool admits 32, so 64 at once is what tells a bound from a wedge.
   Timed, because the failure is a hang rather than a wrong answer. *)

open Lwt.Syntax

let objects : (Stored_key.t, string) Hashtbl.t = Hashtbl.create 8

module Member : Backend_lwt.Store = struct
  let unsupported () = Lwt.fail (Backend.Backend_error "not part of this test")
  let put ~key:_ ~data:_ () = unsupported ()
  let put_if_absent ~key:_ ~data:_ () = unsupported ()
  let get ~key:_ () = unsupported ()

  let get_opt ~key () =
    Lwt.return (Option.map Bigstring.of_string (Hashtbl.find_opt objects key))

  let head_opt ~key:_ () = unsupported ()
  let delete ~key:_ () = unsupported ()
  let delete_multi _ = unsupported ()
  let copy ~src_key:_ ~dst_key:_ () = unsupported ()
  let list_prefix ?max_keys:_ ~prefix:_ () = unsupported ()
  let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

  let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
    Lwt.return `Unsupported

  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps

  (* A native batch, which is what makes the composite declare one too. Yields
     first, so every caller is in flight before any of them finishes. *)
  let get_many =
    Some
      (fun ~entries () ->
        let* () = Lwt.pause () in
        Lwt.return
          (List.map
             (fun (e : Backend.file_entry) ->
               ( e.Backend.key,
                 Option.map Bigstring.of_string
                   (Hashtbl.find_opt objects e.Backend.key) ))
             entries))

  let local_path = None
end

module Store =
  (val Domain_store_lwt.make
         ~mains:[{ Domain_store_lwt.name = "main"; backend = (module Member) }]
         ~targets:[] ~archives:[])

module Batched = Backend_lwt.Batched (Store)

let entry key = Backend.{ key; size = 1; last_modified = 0.; etag = None }

let () =
  Hashtbl.replace objects (Stored_key.listed "a") "alpha";
  let callers = 64 in
  let one () =
    let+ answered =
      Batched.get_many ~entries:[entry (Stored_key.listed "a")] ()
    in
    List.for_all
      (fun (_, b) -> Option.map Bigstring.to_string b = Some "alpha")
      answered
  in
  let settled =
    Lwt_main.run
      (Lwt.pick
         [
           (let+ answers =
              Lwt_list.map_p (fun _ -> one ()) (List.init callers Fun.id)
            in
            if List.for_all Fun.id answers then `All_answered else `Wrong_body);
           (let+ () = Lwt_unix.sleep 10. in
            `Wedged);
         ])
  in
  Printf.printf "%d batches at once through a composite: %s\n" callers
    (match settled with
      | `All_answered -> "all answered"
      | `Wrong_body -> "answered wrongly"
      | `Wedged -> "WEDGED — a batch is queueing behind itself");
  if settled <> `All_answered then exit 1
