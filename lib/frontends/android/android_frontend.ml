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
let is_local = Manifest.is_local

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

module Make (C : Conf.S) = struct
  module E = Domain_engine.Make (C)
  module F = E.F
  module Ih = E.Ih

  let hooks =
    Ih.
      {
        (* The client addresses files by storage key, not by a path in some
           mount it can see, so evict/restore/revert arrive already resolved. *)
        path_to_key = Fun.id;
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

  (* Bytes on stdout rather than into a file the caller reads back: the range a
     ProxyFileDescriptorCallback asks for goes straight into the ByteArray it
     was handed. *)
  let read key ~offset ~length =
    run ~staging:false (fun () ->
        let open Lwt.Syntax in
        let buf = Bigstringaf.create length in
        let+ n = F.read key buf ~offset:(Int64.of_int offset) in
        (* The count is what the caller reads, not something it is told: stdout
           carries exactly [n] bytes, short only at end of file. Saying it again
           on stderr would put it in the stream the log already uses. *)
        print_string (Bigstringaf.substring buf ~off:0 ~len:n))

  (* No daemon to describe, so this reports the domain alone. [Diagnostics.text]
     is the one renderer, so a report from a phone reads like any other. *)
  let status () =
    run ~staging:false (fun () ->
        let open Lwt.Syntax in
        let module D = Diagnostics.Make (C) in
        let+ json = D.domain_json () in
        print_endline
          (Diagnostics.text
             (Diagnostics.merge
                [
                  `Assoc
                    (Diagnostics.self_json
                       ~extra:[("frontend", `String implementation)]
                       ()
                    @ [("domains", `List [json])]);
                ])))

  let start () =
    let open Lwt.Syntax in
    (Lwt.async_exception_hook :=
       fun exn ->
         Log.err "%s: async exception: %s" implementation
           (Printexc.to_string exn));
    Lwt_main.run
      (let* () =
         E.start
           ~freshness:
             (* The client holds no view to invalidate: a DocumentsProvider is
                asked to list again on every access. *)
             Frontend.Revalidates
           ~on_upload_done:(fun ~key:_ -> Lwt.return_unit)
           ()
       in
       (* [Ipc.serve] returns when a client sends [stop]. *)
       let* () = Ipc.serve ~path:C.socket_path (Ih.handler hooks) in
       E.drain ())
end

let start_binding (b : Frontend.binding) =
  (* Leaf process (post-fork): safe to initialize Lwt now. *)
  Frontend.cap_blocking_pool ~concurrency:(Frontend.binding_concurrency [b]);
  let module C = (val b.Frontend.conf : Conf.S) in
  Log.set_prefix (Printf.sprintf "[%s] " C.domain_name);
  let module R = Make (C) in
  R.start ()

(* One process per domain, each with its own socket, as FUSE does — the last
   runs in this process, so the common single-domain case never forks. *)
let start bindings = Frontend.run_forked start_binding bindings

(* Positional arguments: the caller is an app, and a flag grammar would have to
   be parsed by the binary, which does not know this frontend's verbs. *)
let command verb doc run = { Frontend.verb; doc; run }

let commands =
  [
    command "stat" "Describe one item, named by storage key."
      (fun (module C : Conf.S) args ->
        let module R = Make (C) in
        match args with
          | [key] ->
              R.answer ~staging:false (request "stat" [("path", `String key)])
          | _ -> usage "stat" "KEY");
    command "list" "List the children of one directory key."
      (fun (module C : Conf.S) args ->
        let module R = Make (C) in
        match args with
          | [key] ->
              R.answer ~staging:false
                (request "list_dir" [("path", `String key)])
          | _ -> usage "list" "KEY");
    command "read"
      "Write to stdout the LENGTH bytes of KEY at OFFSET, fewer only at end of \
       file." (fun (module C : Conf.S) args ->
        let module R = Make (C) in
        match args with
          | [key; offset; length] ->
              R.read key
                ~offset:(int_arg "read" "OFFSET" offset)
                ~length:(int_arg "read" "LENGTH" length)
          | _ -> usage "read" "KEY OFFSET LENGTH");
    command "fetch"
      "Assemble the whole content of KEY into DEST, fetching what is missing."
      (fun (module C : Conf.S) args ->
        let module R = Make (C) in
        match args with
          | [key; dest] ->
              R.answer ~staging:false
                (request "ensure_cached"
                   [("path", `String key); ("dest", `String dest)])
          | _ -> usage "fetch" "KEY DEST");
    command "write-whole"
      "Make STAGING the whole content of KEY. The file is adopted by rename, \
       so it is gone on success." (fun (module C : Conf.S) args ->
        let module R = Make (C) in
        match args with
          | [key; staging] ->
              R.answer ~staging:true
                (request "write"
                   [("path", `String key); ("staging", `String staging)])
          | _ -> usage "write-whole" "KEY STAGING");
    command "create" "Create an empty file at KEY."
      (fun (module C : Conf.S) args ->
        let module R = Make (C) in
        match args with
          | [key] ->
              R.answer ~staging:true (request "create" [("path", `String key)])
          | _ -> usage "create" "KEY");
    command "mkdir" "Create the directory KEY." (fun (module C : Conf.S) args ->
        let module R = Make (C) in
        match args with
          | [key] ->
              R.answer ~staging:true (request "mkdir" [("path", `String key)])
          | _ -> usage "mkdir" "KEY");
    command "delete" "Delete the file KEY." (fun (module C : Conf.S) args ->
        let module R = Make (C) in
        match args with
          | [key] ->
              R.answer ~staging:true (request "delete" [("path", `String key)])
          | _ -> usage "delete" "KEY");
    command "rmdir" "Remove the directory KEY." (fun (module C : Conf.S) args ->
        let module R = Make (C) in
        match args with
          | [key] ->
              R.answer ~staging:true (request "rmdir" [("path", `String key)])
          | _ -> usage "rmdir" "KEY");
    command "rename" "Rename SRC to DST." (fun (module C : Conf.S) args ->
        let module R = Make (C) in
        match args with
          | [src; dst] ->
              R.answer ~staging:true
                (request "rename" [("src", `String src); ("path", `String dst)])
          | _ -> usage "rename" "SRC DST");
    command "status" "Report this domain: cache, backlog and backends."
      (fun (module C : Conf.S) args ->
        let module R = Make (C) in
        match args with [] -> R.status () | _ -> usage "status" "");
  ]

let () =
  Frontend.register implementation ~cli_group:"android" ~commands
    (module struct
      let is_local = is_local
      let start = start
    end : Frontend.S)
