(* A domain the Android app drives one command at a time.

   There is no daemon because a long-lived process fights the platform: a
   dataSync foreground service is stopped after about six hours a day, and the
   app's exec'd child is reaped while its Service object survives.

   Exiting between calls loses nothing, which is why there is no ranged write
   and no close though FUSE has both: every operation is a function of key and
   offset whose state is already on disk, and a command may not leave a file
   staged for the next one to finish -- [Replay.reconcile] runs first and
   publishes what it finds. Android needs neither, its DocumentsProvider
   committing a whole staged body through [write-whole]. *)

let implementation = "android"
let is_local = Checkout.is_local

(* Through the daemon's own request handler rather than a second implementation
   of it: [ref]/[parentRef] naming, the staged-versus-published rules and the
   error vocabulary are shared with the macOS File Provider, and the wire format
   a caller parses is unchanged. *)
let request action fields =
  Yojson.Safe.to_string (`Assoc (("action", `String action) :: fields))

let usage verb args =
  Printf.eprintf "tsync android %s: %s\n" verb args;
  exit 2

let int_arg verb what s =
  match int_of_string_opt s with
    | Some n -> n
    | None -> usage verb (Printf.sprintf "%s must be a number, got %S" what s)

module Make (C : Conf_lwt.S) = struct
  module Lk = Logical_key.Make (C)
  module E = Domain_engine.Make (C)
  module F = E.F
  module Ih = E.Ih

  let hooks =
    Ih.
      {
        (* The client addresses files by storage key, not by a path in some
           mount it can see, so evict/restore/revert arrive already resolved. *)
        (* ponytail: single key only. FUSE walks a directory subtree here
           (fuse_fs.ml:184) because a user can point at a folder in Finder;
           lift that if a client ever offers the same gesture. *)
        evict = F.evict;
        restore = F.ensure_cached;
        (* Nothing here holds a materialised copy to invalidate: the client
           re-queries, and [sync --full] has already rebuilt the mirror before
           it signals us. *)
        changed = (fun _ -> ());
        full_resync = (fun () -> Lwt.return_unit);
        status_fields = (fun () -> []);
        (* Name the frontend these numbers belong to — a domain can run several,
           each with its own counters. *)
        stats_fields =
          (fun () -> ("frontend", `String implementation) :: E.stats_fields ());
        on_stop = (fun () -> ());
      }

  (* [staging] says whether the verb may leave work owed, which is what needs
     the upload queue running; every verb needs the manifest tree either way.
     Draining is unconditional: with no daemon holding a queue, this returning is
     the only backpressure a caller gets. *)
  let run ~staging f =
    let open Lwt.Syntax in
    (* Detached work has no caller to fail, and the default hook ends the
       process over a background error the log would have carried. *)
    (Lwt.async_exception_hook :=
       fun exn ->
         Log.err "%s: async exception: %s" implementation
           (Printexc.to_string exn));
    Lwt_main.run
      (let* () = if staging then E.start_queue () else E.init () in
       let* () = f () in
       E.drain ())

  (* The handler's continuation is meaningless here: a process that has answered
     is about to exit, which is every one of `Continue, `Stop and `Subscribe. *)
  let answer ~staging req =
    run ~staging (fun () ->
        let open Lwt.Syntax in
        let+ reply, _ = Ih.handler hooks req in
        print_string reply;
        print_newline ())

  (* One process for the whole of an open file, reading ranges until its caller
     closes stdin.

     The ranges are no different from what {!read} serves one at a time; what
     the process buys is what only exists while it lives. [Data.pread] records
     where each read ended and fetches the chunks after it when the next one
     continues there (lib/content/data.ml read_ahead), so a reader is served out
     of the cache while the network runs ahead of it. An invocation per range
     cannot: the table it consults is empty at every start, and the fetch it
     would launch dies with it.

     A request is "OFFSET LENGTH" on a line. Each answer is a JSON line carrying
     the count, then that many bytes, so a caller frames on the count rather
     than looking for a delimiter in binary. *)
  (* The argument is a storage key as the client spells it; one this domain
     cannot read names nothing here. *)
  let session raw =
    match Lwt_main.run (Ih.key_of_ref raw) with
      | None ->
          prerr_endline ("not an item this domain can name: " ^ raw);
          exit 1
      | Some key ->
          run ~staging:false (fun () ->
              let open Lwt.Syntax in
              let reply fields =
                let* () =
                  Lwt_io.write_line Lwt_io.stdout
                    (Yojson.Safe.to_string
                       (`Assoc (("ok", `Bool true) :: fields)))
                in
                Lwt_io.flush Lwt_io.stdout
              in
              let refuse code msg =
                let* () =
                  Lwt_io.write_line Lwt_io.stdout
                    (Yojson.Safe.to_string
                       (`Assoc
                          [
                            ("ok", `Bool false);
                            ("code", `String code);
                            ("error", `String msg);
                          ]))
                in
                Lwt_io.flush Lwt_io.stdout
              in
              let* resolved = F.resolve key in
              match resolved with
                | None ->
                    refuse "not_found"
                      ("not found: " ^ Logical_key.to_string key)
                | Some published ->
                    let size =
                      match published with
                        | `Staged (st, _) ->
                            Int64.to_int st.Staged_manifest.s_size
                        | `Published m -> Int64.to_int (Manifest.size m)
                    in
                    let* () = reply [("size", `Int size)] in
                    let rec serve () =
                      let* line = Lwt_io.read_line_opt Lwt_io.stdin in
                      match line with
                        (* The caller is gone; so is any reason to be here. *)
                        | None -> Lwt.return_unit
                        | Some line -> (
                            match
                              List.filter_map int_of_string_opt
                                (String.split_on_char ' ' (String.trim line))
                            with
                              | [offset; length] when offset >= 0 && length > 0
                                ->
                                  let buf = Bigstringaf.create length in
                                  let* n =
                                    F.read key buf ~offset:(Int64.of_int offset)
                                  in
                                  let* () = reply [("length", `Int n)] in
                                  let* () =
                                    Lwt_io.write Lwt_io.stdout
                                      (Bigstringaf.substring buf ~off:0 ~len:n)
                                  in
                                  let* () = Lwt_io.flush Lwt_io.stdout in
                                  serve ()
                              | _ ->
                                  let* () =
                                    refuse "invalid"
                                      "expected \"OFFSET LENGTH\""
                                  in
                                  serve ())
                    in
                    serve ())

  (* What of [key] is already on this device, for a caller deciding whether to
     assemble the whole thing rather than page through it. *)
  let residency raw =
    match Lwt_main.run (Ih.key_of_ref raw) with
      | None ->
          prerr_endline ("not an item this domain can name: " ^ raw);
          exit 1
      | Some key ->
          run ~staging:false (fun () ->
              let open Lwt.Syntax in
              let+ cached, total = F.chunk_residency key in
              print_endline
                (Yojson.Safe.to_string
                   (`Assoc
                      [
                        ("ok", `Bool true);
                        ("cached", `Int cached);
                        ("total", `Int total);
                      ])))

  (* No daemon to describe, so this reports the domain alone: the same fold with
     nobody to ask, so a report from a phone reads like any other. *)
  let status () =
    run ~staging:false (fun () ->
        let open Lwt.Syntax in
        let module D = Diagnostics.Make (C) in
        let+ json = D.domain_json () in
        print_endline
          (Status_report.text
             (Status_report.of_answers
                ~local:
                  (Diagnostics.self_json
                     ~extra:[("frontend", `String implementation)]
                     ())
                ~domains:[json] [])))
end

(* There is nothing to start. Serving a socket here would put a second way to
   reach a domain beside the commands, and the two would answer differently the
   moment one of them grew a feature — so `tsync start' on a domain configured
   this way says so rather than sitting there. The launcher refuses on the
   topology before it forks, so this is only reached if that check is lost. *)
let start (_ : Frontend.served list) =
  failwith
    "the android frontend is driven by commands, not by a daemon: see `tsync \
     android --help'"

(* Positional arguments: the caller is an app, and a flag grammar would have to
   be parsed by the binary, which does not know this frontend's verbs. *)
let command verb doc run = { Frontend.verb; doc; run }

let commands =
  [
    command "stat" "Describe one item, named by reference."
      (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with
          | [r] -> R.answer ~staging:false (request "stat" [("ref", `String r)])
          | _ -> usage "stat" "REF");
    command "list" "List the children of one directory reference."
      (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with
          | [r] ->
              R.answer ~staging:false (request "list_dir" [("ref", `String r)])
          | _ -> usage "list" "REF");
    command "read"
      "Write LENGTH bytes of KEY from OFFSET into DEST at that same offset, \
       leaving the rest of DEST sparse." (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with
          | [r; dest; offset; length] ->
              R.answer ~staging:false
                (request "fetch_range"
                   [
                     ("ref", `String r);
                     ("dest", `String dest);
                     ("offset", `Int (int_arg "read" "OFFSET" offset));
                     ("length", `Int (int_arg "read" "LENGTH" length));
                   ])
          | _ -> usage "read" "REF DEST OFFSET LENGTH");
    command "open"
      "Serve ranges of REF until stdin closes: a size line, then one JSON \
       length line and that many bytes per \"OFFSET LENGTH\" request."
      (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with [r] -> R.session r | _ -> usage "open" "REF");
    command "residency" "Report how many of REF's chunks are on this device."
      (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with [r] -> R.residency r | _ -> usage "residency" "REF");
    command "fetch"
      "Assemble the whole content of REF into DEST, fetching what is missing."
      (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with
          | [r; dest] ->
              R.answer ~staging:false
                (request "ensure_cached"
                   [("ref", `String r); ("dest", `String dest)])
          | _ -> usage "fetch" "REF DEST");
    command "write-whole"
      "Make STAGING the whole content of NAME under PARENT. The file is \
       adopted by rename, so it is gone on success."
      (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with
          | [parent; name; staging] ->
              R.answer ~staging:true
                (request "write"
                   [
                     ("parentRef", `String parent);
                     ("name", `String name);
                     ("staging", `String staging);
                   ])
          | _ -> usage "write-whole" "PARENT NAME STAGING");
    command "create" "Create an empty file NAME under PARENT."
      (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with
          | [parent; name] ->
              R.answer ~staging:true
                (request "create"
                   [("parentRef", `String parent); ("name", `String name)])
          | _ -> usage "create" "PARENT NAME");
    command "mkdir" "Create the directory NAME under PARENT."
      (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with
          | [parent; name] ->
              R.answer ~staging:true
                (request "mkdir"
                   [("parentRef", `String parent); ("name", `String name)])
          | _ -> usage "mkdir" "PARENT NAME");
    command "delete" "Delete the file KEY." (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with
          | [r] ->
              R.answer ~staging:true (request "delete" [("ref", `String r)])
          | _ -> usage "delete" "REF");
    command "rmdir" "Remove the directory KEY."
      (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with
          | [r] -> R.answer ~staging:true (request "rmdir" [("ref", `String r)])
          | _ -> usage "rmdir" "REF");
    command "rename" "Move SRC under PARENT, naming it NAME."
      (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with
          | [src; parent; name] ->
              R.answer ~staging:true
                (request "rename"
                   [
                     ("ref", `String src);
                     ("parentRef", `String parent);
                     ("name", `String name);
                   ])
          | _ -> usage "rename" "SRC PARENT NAME");
    command "status" "Report this domain: cache, backlog and backends."
      (fun (module C : Conf_lwt.S) args ->
        let module R = Make (C) in
        match args with [] -> R.status () | _ -> usage "status" "");
  ]

let register () =
  Frontend.register implementation ~cli_group:"android" ~commands
    (module struct
      let is_local = is_local
      let topology = `Not_a_daemon
      let listens = None
      let start = start
    end : Frontend.S)
