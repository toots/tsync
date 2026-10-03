open Tsync_core
open Tsync_config
open Tsync_owner
open Tsync_ipc

(* Bad usage: the arguments a verb takes, or what is wrong with one. *)
exception Usage of string option

let usage () = raise (Usage None)

(* android §2, §7: an owner for the call, drained before it exits; only a
   mutating action starts the queues. *)
let owning ~domain ~start f =
  let config, dom = Android_host.load domain in
  let owner =
    Owner.embed ~start ~role:"command" ~what:"tsync android"
      ~roots:[Paths.home ()]
      ~publish:(fun _ -> 0)
      ~frontend:Android_host.frontend config dom
  in
  Fun.protect
    ~finally:(fun () ->
      let (module E : Tsync_sync.Engine.S) = owner.engine in
      Fun.protect ~finally:(fun () -> Owner.release owner.lock) E.drain)
    (fun () -> f owner)

let mutates text =
  match Protocol.decode (Yojson.Safe.from_string text) with
    | Request r -> Protocol.mutates r
    | exception _ -> false

let succeeded reply =
  match Yojson.Safe.from_string reply with
    | `Assoc l -> List.assoc_opt "ok" l = Some (`Bool true)
    | _ | (exception _) -> false

let send ~domain text =
  owning ~domain ~start:(mutates text) (fun owner ->
      let reply = Android_host.request_in owner text in
      print_endline reply;
      if succeeded reply then 0 else 1)

let action name fields ~domain =
  send ~domain
    (Yojson.Safe.to_string (`Assoc (("action", `String name) :: fields)))

let str k v = (k, `String v)

let number k v =
  match int_of_string_opt v with
    | Some n -> (k, `Int n)
    | None ->
        raise (Usage (Some (Printf.sprintf "%s must be a number, not %S" k v)))

let place parent name = [str "parentRef" parent; str "name" name]

(* Framing is by count, never by delimiter. *)
let session ~domain ref_ =
  owning ~domain ~start:false (fun owner ->
      let say json = print_endline (Yojson.Safe.to_string json) in
      let handle = Android_host.open_in owner ref_ in
      if handle < 0 then (
        say
          (Ipc.failure
             (Fail.make
                (if handle = -2 then Fail.Absent else Fail.Unexplained)
                (Printf.sprintf "%s cannot be opened (errno %d)" ref_ (-handle))));
        1)
      else
        Fun.protect
          ~finally:(fun () -> ignore (Android_host.close handle))
          (fun () ->
            say (Ipc.ok [("size", `Int (Android_host.size handle))]);
            let serve line =
              match
                List.map int_of_string_opt
                  (String.split_on_char ' ' (String.trim line))
              with
                | [Some off; Some len] when off >= 0 && len > 0 -> (
                    let buffer = Bigstring.create len in
                    match Android_host.read_in owner handle ~off buffer with
                      | n when n >= 0 ->
                          say (Ipc.ok [("length", `Int n)]);
                          print_string
                            (Bigstring.to_string ~off:0 ~len:n buffer);
                          flush stdout
                      | errno ->
                          say
                            (Ipc.failure
                               (Fail.make Fail.Unexplained
                                  (Printf.sprintf "read failed (errno %d)"
                                     (-errno)))))
                | _ ->
                    say
                      (Ipc.failure
                         (Fail.make Fail.Invalid
                            "a read is \"OFFSET LENGTH\", offset ≥ 0 and \
                             length > 0"))
            in
            (try
               while true do
                 serve (input_line stdin)
               done
             with End_of_file -> ());
            0))

let residency ~domain ref_ =
  owning ~domain ~start:false (fun owner ->
      let (module E : Tsync_sync.Engine.S) = owner.engine in
      let reply =
        match E.residency (Handler.path_of_ref owner.handler ref_) with
          | cached, total ->
              Ipc.ok [("cached", `Int cached); ("total", `Int total)]
          | exception e -> Ipc.failure (Fail.classify e)
      in
      print_endline (Yojson.Safe.to_string reply);
      if succeeded (Yojson.Safe.to_string reply) then 0 else 1)

let status ~domain =
  owning ~domain ~start:false (fun owner ->
      print_string (Android_host.status_in owner);
      0)

let verbs :
    (string * string * string * (domain:string -> string list -> int)) list =
  let on_ref name ~domain = function
    | [r] -> action name [str "ref" r] ~domain
    | _ -> usage ()
  and in_place ?(more = []) name ~domain = function
    | [parent; leaf] -> action name (place parent leaf @ more) ~domain
    | _ -> usage ()
  in
  [
    ("stat", "REF", "An item's row.", on_ref "stat");
    ( "list",
      "REF [AFTER [LIMIT]]",
      "A folder's children.",
      fun ~domain -> function
        | [r] -> action "list_dir" [str "ref" r] ~domain
        | [r; after] ->
            action "list_dir" [str "ref" r; str "after" after] ~domain
        | [r; after; limit] ->
            action "list_dir"
              [str "ref" r; str "after" after; number "limit" limit]
              ~domain
        | _ -> usage () );
    ( "read",
      "REF DEST OFFSET LENGTH",
      "A range of a file, written into DEST at the same offset.",
      fun ~domain -> function
        | [r; dest; offset; length] ->
            action "fetch_range"
              [
                str "ref" r;
                str "dest" dest;
                number "offset" offset;
                number "length" length;
              ]
              ~domain
        | _ -> usage () );
    ( "open",
      "REF",
      "Serve reads of one version: \"OFFSET LENGTH\" lines on stdin.",
      fun ~domain -> function [r] -> session ~domain r | _ -> usage () );
    ( "residency",
      "REF",
      "How much of a file is on this machine.",
      fun ~domain -> function [r] -> residency ~domain r | _ -> usage () );
    ( "fetch",
      "REF DEST",
      "A whole file into DEST.",
      fun ~domain -> function
        | [r; dest] ->
            action "ensure_cached" [str "ref" r; str "dest" dest] ~domain
        | _ -> usage () );
    ( "write-whole",
      "PARENT NAME STAGING",
      "Adopt a staged file as PARENT/NAME and wait for its upload.",
      fun ~domain -> function
        | [parent; leaf; staging] ->
            action "write"
              (place parent leaf
              @ [str "staging" staging; ("await", `Bool true)])
              ~domain
        | _ -> usage () );
    ("create", "PARENT NAME", "An empty file.", in_place "create");
    ("mkdir", "PARENT NAME", "A folder.", in_place "mkdir");
    ("delete", "REF", "Remove a file.", on_ref "delete");
    ("rmdir", "REF", "Remove a folder and its subtree.", on_ref "rmdir");
    ( "rename",
      "SRC PARENT NAME",
      "Move or rename an item.",
      fun ~domain -> function
        | [src; parent; leaf] ->
            action "rename" (str "ref" src :: place parent leaf) ~domain
        | _ -> usage () );
    ("share", "REF", "A public link to an item.", on_ref "share");
    ( "request",
      "JSON",
      "One request, verbatim: the wire a host speaks.",
      fun ~domain -> function [json] -> send ~domain json | _ -> usage () );
    ( "status",
      "",
      "The status text.",
      fun ~domain -> function [] -> status ~domain | _ -> usage () );
  ]

let commands : Frontend.command list =
  List.map
    (fun (verb, args, doc, run) ->
      {
        Frontend.verb;
        doc;
        run =
          (fun ~domain argv ->
            try run ~domain argv
            with Usage wrong ->
              Printf.eprintf "tsync: %s\n%!"
                (match wrong with
                  | Some wrong -> wrong
                  | None ->
                      Printf.sprintf "usage: tsync android %s %s" verb args);
              2);
      })
    verbs
