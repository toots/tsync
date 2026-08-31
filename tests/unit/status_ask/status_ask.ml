(* What a collector puts on the wire, and what it makes of the answer.

   The field worth pinning is [domain]. macOS runs one daemon behind every
   domain and routes [stats] on it, so a request that omits it can only be
   answered where there is exactly one domain to guess. *)

open Lwt.Syntax

(* The pid, so instances running beside each other do not bind and unlink the
   same socket. *)
let socket_path =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-ask-%d.sock" (Unix.getpid ()))

(* Echoes the request back as the reply's [asked] field, so the snapshot below
   shows what was sent as well as what came of it. *)
let serve ~reply =
  let handler line =
    let asked = Yojson.Safe.from_string line in
    Lwt.return
      (Yojson.Safe.to_string (`Assoc (("asked", asked) :: reply)), `Continue)
  in
  Ipc_lwt.serve ~path:socket_path handler

let mount_reply =
  [
    ("ok", `Bool true);
    ( "server",
      `Assoc
        [
          ("pid", `Int 18103);
          ("uptimeSeconds", `Float 3600.);
          ("hostname", `String "testhost");
        ] );
    ( "process",
      `Assoc [("cpuSeconds", `Float 35.5); ("rssBytes", `Int 57638912)] );
    ("traffic", `Assoc [("bytesUploaded", `Int 4096)]);
    ( "domains",
      `List
        [
          `Assoc
            [
              ("name", `String "alpha");
              ( "frontends",
                `List
                  [`Assoc [("type", `String "fuse"); ("stagedFiles", `Int 2)]]
              );
            ];
          `Assoc
            [
              ("name", `String "beta");
              ( "frontends",
                `List
                  [`Assoc [("type", `String "fuse"); ("stagedFiles", `Int 9)]]
              );
            ];
        ] );
  ]

(* Bound, rather than a guess at how long binding takes: [serve] binds in a
   thread of its own, and the pause this replaces was fifty milliseconds, which
   a loaded runner spends without getting there. What that produced was not a
   timeout but a snapshot of an answer nobody gave. *)
let rec await_bound tries =
  if Sys.file_exists socket_path then Lwt.return_unit
  else if tries <= 0 then
    Lwt.fail (Failure "status_ask: the daemon never bound its socket")
  else
    let* () = Lwt_unix.sleep 0.01 in
    await_bound (tries - 1)

let show name json =
  Printf.printf "=== %s\n%s\n\n" name (Yojson.Safe.pretty_to_string json)

let () =
  (try Unix.unlink socket_path with _ -> ());
  Lwt_main.run
    (let server = serve ~reply:mount_reply in
     let* () = await_bound 500 in
     (* The domain travels, and the arg with it. *)
     let* a =
       Status_report.ask ~arg:Status_report.frontend_only ~frontend:"fuse"
         ~domain:"beta" ~socket_path ()
     in
     show "the request, as the daemon received it"
       (Yojson.Safe.Util.member "asked" a.Status_report.reply);
     (* The domain asked about, not whichever the daemon listed first. *)
     show "the entry it contributes to beta" (Status_report.frontend_entry a);
     Lwt.cancel server;
     Lwt.return_unit);
  (try Unix.unlink socket_path with _ -> ());
  (* Nothing listening: an answer saying so, naming the frontend that is silent
     so a reader learns which one rather than that "something" is. *)
  Lwt_main.run
    (let+ a =
       Status_report.ask ~timeout:0.2 ~frontend:"fuse" ~domain:"alpha"
         ~socket_path ()
     in
     show "a socket nothing is bound to"
       (match Status_report.frontend_entry a with
         | `Assoc fields ->
             (* The path is a temp dir, which differs by machine. *)
             `Assoc
               (List.map
                  (fun (k, v) ->
                    if k = "socketPath" then (k, `String "<socket>")
                    else if k = "error" then (k, `String "<error>")
                    else (k, v))
                  fields)
         | j -> j))
