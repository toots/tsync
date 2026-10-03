(* android §9, Command group: every verb driven by a spawned process per call,
   replies shown in full, and the registered verbs exactly the ones driven. *)

open Tsync_core

let p fmt = Printf.printf (fmt ^^ "\n%!")

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-acli-%d" (Unix.getpid ()))

let home = Filename.concat root "home"
let tsync = Sys.argv.(1)
let driven = Hashtbl.create 16

(* Ids and hashes differ between runs; times too. *)
let ids = Hashtbl.create 16

let placeholder kind id =
  match Hashtbl.find_opt ids id with
    | Some k -> k
    | None ->
        let k = Printf.sprintf "<%s%d>" kind (Hashtbl.length ids + 1) in
        Hashtbl.replace ids id k;
        k

let scrub_ref r =
  if String.length r > 2 && r.[1] = ':' then
    String.sub r 0 2
    ^ placeholder
        (if r.[0] = 'd' then "folder" else "file")
        (String.sub r 2 (String.length r - 2))
  else r

let rec scrub : Yojson.Safe.t -> Yojson.Safe.t = function
  | `Assoc l ->
      `Assoc
        (List.map
           (fun (k, v) ->
             ( k,
               match (k, v) with
                 | ("ref" | "parentRef"), `String r -> `String (scrub_ref r)
                 | ("etag" | "contentId"), `String h
                   when h <> "" && h <> ".tsync-root" ->
                     `String
                       (placeholder
                          (if String.contains h '-' then "folder" else "hash")
                          h)
                 | "mtime", `Float t when t > 0. -> `String "<time>"
                 | ("pulledAt" | "expires"), _ -> `String "<time>"
                 | "url", _ -> `String "<url>"
                 | ("localPath" | "error"), `String s ->
                     `String
                       (String.concat "<home>"
                          (String.split_on_char '\000'
                             (let n = String.length home in
                              let b = Buffer.create 64 in
                              let i = ref 0 in
                              while !i < String.length s do
                                if
                                  !i + n <= String.length s
                                  && String.sub s !i n = home
                                then (
                                  Buffer.add_char b '\000';
                                  i := !i + n)
                                else (
                                  Buffer.add_char b s.[!i];
                                  incr i)
                              done;
                              Buffer.contents b)))
                 | _ -> scrub v ))
           l)
  | `List l -> `List (List.map scrub l)
  | j -> j

let spawn ?(input = "") args =
  let out = Filename.concat root "out" and inp = Filename.concat root "in" in
  Fs.write_file_for_test inp input;
  let fd_out = Unix.openfile out [O_WRONLY; O_CREAT; O_TRUNC] 0o600 in
  let fd_in = Unix.openfile inp [O_RDONLY] 0 in
  let pid =
    Unix.create_process tsync
      (Array.of_list (tsync :: "android" :: args))
      fd_in fd_out Unix.stderr
  in
  Unix.close fd_out;
  Unix.close fd_in;
  let _, status = Unix.waitpid [] pid in
  ((match status with WEXITED n -> n | _ -> -1), Fs.read_file out)

(* One call: its reply, and the reply parsed for what the next call names.
   [racing] names the item fields that depend on whether the file's upload
   finished before the reply was built; they are not shown. *)
let run ?(racing = []) args =
  Hashtbl.replace driven (List.hd args) ();
  let code, out = spawn args in
  let settled = function
    | `Assoc l ->
        `Assoc
          (List.map
             (function
               | "item", `Assoc item ->
                   ( "item",
                     `Assoc
                       (List.filter
                          (fun (k, _) -> not (List.mem k racing))
                          item) )
               | kv -> kv)
             l)
    | j -> j
  in
  let reply =
    try scrub (settled (Yojson.Safe.from_string out))
    with _ -> `String (String.trim out)
  in
  p "$ tsync android %s\n  exit %d  %s"
    (String.concat " "
       (List.map
          (fun a ->
            if String.length a > 0 && a.[0] = '/' then Filename.basename a
            else scrub_ref a)
          args))
    code
    (Yojson.Safe.to_string reply);
  try Yojson.Safe.from_string out with _ -> `Null

let field j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None

let item_ref j =
  match Option.bind (field j "item") (fun i -> field i "ref") with
    | Some (`String r) -> r
    | _ -> "?"

let staged name content =
  let path = Filename.concat home name in
  Fs.write_file_for_test path content;
  path

let () =
  Fs.rm_rf root;
  List.iter
    (fun (var, dir) ->
      let dir = Filename.concat root dir in
      Fs.mkdir_p ~perm:0o700 dir;
      Unix.putenv var dir)
    [("HOME", "home"); ("XDG_DATA_HOME", "data"); ("XDG_CACHE_HOME", "cache")];
  Unix.putenv "TSYNC_CONFIG_JSON"
    (Printf.sprintf
       {|{"name":"phone","domains":[{"name":"docs","symlinks":"skip","versioning":true,
          "frontends":["android"],
          "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
       root);
  ignore (run ["stat"; "root"]);
  ignore (run ["list"; "root"]);
  let dir = item_ref (run ["mkdir"; "root"; "photos"]) in
  ignore (run ["mkdir"; "root"; "photos"]);
  let empty =
    item_ref
      (run
         ~racing:["etag"; "isUploaded"; "contentId"; "availability"]
         ["create"; dir; "empty.txt"])
  in
  let file =
    item_ref
      (run ["write-whole"; dir; "hello.txt"; staged "s1" "hello, android"])
  in
  ignore (run ["list"; dir]);
  ignore (run ["list"; dir; "empty.txt"; "1"]);
  ignore (run ["stat"; file]);
  ignore (run ["residency"; file]);
  ignore (run ["read"; file; Filename.concat home "range"; "7"; "100"]);
  p "  the range file: %S"
    (String.escaped (Fs.read_file (Filename.concat home "range")));
  ignore (run ["fetch"; file; Filename.concat home "whole"]);
  p "  the whole file: %S" (Fs.read_file (Filename.concat home "whole"));
  ignore (run ["fetch"; file; Filename.concat home "whole"]);
  ignore (run ["residency"; file]);
  Hashtbl.replace driven "open" ();
  let code, out = spawn ~input:"0 5\nnonsense\n7 100\n" ["open"; file] in
  p
    "$ tsync android open %s  <  \"0 5\", \"nonsense\", \"7 100\"\n\
    \  exit %d  %S"
    (scrub_ref file) code out;
  let moved = item_ref (run ["rename"; file; "root"; "moved.txt"]) in
  p "  the reference survived the move: %b" (moved = file);
  ignore
    (run
       [
         "request";
         Printf.sprintf
           {|{"action":"create","parentRef":"root","name":"moved.txt","exclusive":true}|};
       ]);
  ignore (run ["request"; "{nope"]);
  ignore (run ["share"; file]);
  ignore (run ["delete"; empty]);
  ignore (run ["delete"; dir]);
  ignore (run ["rmdir"; dir]);
  ignore (run ["list"; "root"]);
  ignore (run ["stat"]);
  ignore (run ["read"; file; "x"; "seven"; "1"]);
  Hashtbl.replace driven "status" ();
  let code, out = spawn ["status"] in
  p "$ tsync android status\n  exit %d  %s" code
    (if code = 0 && String.length out > 0 then "(the status text)" else out);
  let registered =
    match Tsync_config.Frontend.find "android" with
      | Some f ->
          List.map
            (fun (c : Tsync_config.Frontend.command) -> c.verb)
            f.commands
      | None -> []
  in
  p "registered and not driven: [%s]"
    (String.concat ", "
       (List.filter (fun v -> not (Hashtbl.mem driven v)) registered));
  p "driven and not registered: [%s]"
    (String.concat ", "
       (List.sort compare
          (Hashtbl.fold
             (fun v () acc -> if List.mem v registered then acc else v :: acc)
             driven [])));
  p "verbs driven: %d" (Hashtbl.length driven);
  Fs.rm_rf root;
  exit 0
