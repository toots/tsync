(* Whether a reader waiting on bytes can reach the store while the prefetch is
   using it.

   Both go out through {!Chunk_store}, and what tells them apart is which call
   they make: a whole chunk is what the prefetch fetches ahead of a reader, and
   a range is only ever asked for by someone waiting for it. Sharing one budget
   put the reader in a queue the prefetch refills as fast as it drains, and on a
   phone that was six seconds for every 128 KiB a player asked for.

   The real store, not a double of it: the budget under test belongs to
   {!Chunk_store} itself, and a stand-in for the backend below it is the only
   part that has to be pretend. Parked rather than timed, so what is snapshotted
   is what the budget allowed and not how fast this machine is. *)

open Lwt.Syntax

(* Small enough that the parked fetches below fill it exactly. *)
let budget = 2
let slots = Io_lwt.Bounded.create ~name:"test chunk buffers" ~max:budget ()
let downloads = Io_lwt.Bounded.create ~name:"test downloads" ~max:budget ()
let ranges = Io_lwt.Bounded.create ~name:"test ranges" ~max:budget ()

(* A whole-chunk fetch that never answers: whatever budget it took stays
   taken, which is the prefetch holding the wire. *)
let parked = ref 0

module S = Chunk_store_lwt.Make (struct
  let put ~key:_ ~data:_ () = Lwt.return_unit
  let backend_key key = Stored_key.in_space ~prefix:"tsync/test/chunks/" key
  let present _ = Lwt.return_false
  let corrupt _ = Lwt.return_false
  let cleared _ = ()
  let max_known () = 1024
  let slots = slots
  let downloads = downloads
  let ranges = ranges

  let fetch_body _ =
    incr parked;
    fst (Lwt.wait ())

  let fetch_body_range _ ~offset:_ ~length = Lwt.return (Bigstring.create length)
end)

let settle () =
  let rec go n =
    if n = 0 then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.02 in
      go (n - 1)
  in
  go 10

(* A read that cannot simply be waited for: whether it comes back at all is the
   question. *)
let served t =
  Lwt.pick
    [
      (let+ (_ : Bigstring.t) = t in
       true);
      (let+ () = Lwt_unix.sleep 2. in
       false);
    ]

let () =
  Lwt_main.run
    (for i = 1 to budget do
       Lwt.async (fun () ->
           let+ (_ : Bigstring.t) = S.fetch (Printf.sprintf "chunk-%d" i) in
           ())
     done;
     let* () = settle () in
     print_endline "=== the prefetch holds the download budget";
     Printf.printf "  download budget    %d\n" budget;
     Printf.printf "  parked on it       %d\n" !parked;

     print_endline "";
     print_endline "=== a reader asks for the bytes it is playing";
     let* ok =
       served (S.fetch_range "chunk-wanted" ~offset:0 ~length:(128 * 1024))
     in
     Printf.printf "  range served       %b\n" ok;
     Lwt.return_unit)
