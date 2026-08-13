(* A peer that is not there must be reported, not waited on — and abandoning the
   attempt must not leak the socket.

   {!Http_client} splits its deadline in two: getting a response at all is
   quick against anything that is answering, while streaming a body afterwards
   is real work. A single budget over both had to be the body's, and that is how
   one unplugged machine wedged a domain — every call to it spent the full body
   budget before failing, eight times over with backoff.

   So the assertion is which of the two deadlines ended the call. Timing is
   printed as a band rather than a number: the point is that the call gave up on
   the response deadline, not that it took any particular number of seconds.

   TEST-NET-1 (RFC 5737) is unroutable by definition and drops rather than
   refuses, which is what makes the attempt stall instead of fail. A network
   that answered it with an ICMP unreachable would turn this into a test of
   nothing, so the outcome is printed too: anything but a timeout below and the
   run is not exercising a stalled connection at all. *)

let black_hole = Uri.of_string "http://192.0.2.1:8000"
let attempts = 2
let open_fds () = Array.length (Sys.readdir "/dev/fd")

let attempt client =
  Lwt.catch
    (fun () ->
      Lwt.map
        (fun _ -> "answered")
        (Http_client.call client ~headers:(Cohttp.Header.init ()) `GET
           black_hole))
    (function
      | Lwt_unix.Timeout -> Lwt.return "timed out"
      | exn -> Lwt.return (Printexc.to_string exn))

let () =
  let client = Http_client.create () in
  (* One call first: the descriptors conduit opens once per context (its
     resolver's, chiefly) are not a leak, and counting from a cold process would
     score them as one. *)
  let first = Lwt_main.run (attempt client) in
  let before = open_fds () in
  let started = Unix.gettimeofday () in
  let outcomes =
    List.init attempts (fun _ -> Lwt_main.run (attempt client))
    |> List.sort_uniq compare
  in
  let each = (Unix.gettimeofday () -. started) /. float_of_int attempts in
  let after = open_fds () in
  Printf.printf "first call:        %s\n" first;
  Printf.printf "%d further calls:   %s\n" attempts (String.concat ", " outcomes);
  Printf.printf "gave up on:        %s\n"
    (if each < Http_client.body_timeout /. 2. then "the response deadline"
     else "the body budget");
  (* An abandoned call leaves its connection in the cache holding a socket, which
     the cache closes on its own idle timer — measured, and it does come back to
     zero. So this is occupancy, not a leak, and what matters is that it stays
     proportional to the calls made: anything above one apiece means a call is
     dialling more than once, which is how a bounded wait turns back into an
     unbounded one. *)
  Printf.printf "sockets held:      %s\n"
    (let held = after - before in
     if held <= attempts then "one per abandoned call, at most"
     else Printf.sprintf "%d for %d calls" held attempts)
