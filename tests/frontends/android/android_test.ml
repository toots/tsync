(* The Android frontend's command surface, driven the way the app drives it:
   one process per call.

   Spawning is the point. Every other test of these operations runs them in one
   process, where the caches, the staged manifests and the Lwt loop all persist
   -- exactly the state this design claims not to need, so an in-process check
   would pass on a frontend that only works as a daemon. *)

open Check

let binary =
  (* The generated rule depends on it (deps_for in tests/gen-dune.sh), so it is
     built; dune runs this from its own directory, hence the walk up. *)
  let rec find dir depth =
    if depth = 0 then None
    else (
      let candidate = Filename.concat dir "bin/tsync.exe" in
      if Sys.file_exists candidate then Some candidate
      else find (Filename.dirname dir) (depth - 1))
  in
  find (Sys.getcwd ()) 6

let root = Filename.temp_dir "tsync-android" ""
let home = Filename.concat root "home"
let store = Filename.concat root "store"

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let mkdir_p path =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))

let exercised : (string, unit) Hashtbl.t = Hashtbl.create 16

(* stderr carries the log, which the snapshot rule discards: what a caller
   parses is stdout and nothing else. *)
let run args =
  (match args with
    | "android" :: verb :: _ -> Hashtbl.replace exercised verb ()
    | _ -> ());
  let exe = Option.get binary in
  let out = Filename.concat root "out.bin" in
  let quoted = List.map Filename.quote (exe :: args) in
  let cmd =
    Printf.sprintf "HOME=%s %s > %s 2>/dev/null" (Filename.quote home)
      (String.concat " " quoted) (Filename.quote out)
  in
  ignore (Sys.command cmd);
  read_file out

(* Enough to pull one scalar out of a reply without a parser. The first
   occurrence, which for [name] and [items] is the one being asked about. *)
let json_field name body =
  let needle = Printf.sprintf "\"%s\":" name in
  let n = String.length needle and h = String.length body in
  let rec at i =
    if i + n > h then None
    else if String.sub body i n = needle then Some (i + n)
    else at (i + 1)
  in
  match at 0 with
    | None -> None
    | Some start ->
        let rec stop i =
          if i >= h then i
          else (match body.[i] with ',' | '}' -> i | _ -> stop (i + 1))
        in
        Some (String.sub body start (stop start - start))

let fixture = "0123456789ABCDEFghijklmn"

let () =
  match binary with
    | None ->
        (* Never a silent skip: the suite exists to exercise a binary, and one
           that is not there is a result, not an absence of one. *)
        print_endline
          "no tsync binary found; the generated rule should depend on it";
        exit 1
    | Some _ ->
        (* Chunks of 8 bytes, so the 24-byte fixture below spans three of them
           and a ranged read crosses a boundary. *)
        mkdir_p (Filename.concat home ".config/tsync");
        mkdir_p store;
        write_file
          (Filename.concat home ".config/tsync/config.json")
          (Printf.sprintf
             {|{ "name": "test",
  "domains": [ { "name": "media", "versioning": true, "symlinks": "skip",
    "maxCache": "1G", "chunkSize": 8, "cacheChunkSize": 8,
    "frontends": ["android"],
    "backends": [ { "type": "local", "name": "store", "role": "main", "path": %S } ] } ] }|}
             store);

        case "a directory is made, then seen";
        step "mkdir media/photos/";
        let reply = run ["android"; "mkdir"; "media/photos/"] in
        check "mkdir answers ok" (json_field "ok" reply = Some "true");
        let listing = run ["android"; "list"; "media/"] in
        check "the new directory is listed"
          ~why:(fun () -> listing)
          (json_field "name" listing = Some "\"photos\"");

        case "a whole body is adopted, and read back byte for byte";
        let staging = Filename.concat root "staged.bin" in
        write_file staging fixture;
        step "write-whole media/photos/big.txt";
        let written =
          run ["android"; "write-whole"; "media/photos/big.txt"; staging]
        in
        check "write-whole reports the size"
          ~why:(fun () -> written)
          (json_field "size" written = Some "24");
        check "the staging file was adopted by rename, not copied"
          (not (Sys.file_exists staging));
        let whole =
          run ["android"; "read"; "media/photos/big.txt"; "0"; "24"]
        in
        check "a whole read returns the content"
          ~why:(fun () -> whole)
          (whole = fixture);

        case "ranges, each served by its own process, reassemble the file";
        (* Nothing is held between calls, so three processes reading a range
           each is the same as one reading all of it. *)
        let a = run ["android"; "read"; "media/photos/big.txt"; "0"; "8"] in
        let b = run ["android"; "read"; "media/photos/big.txt"; "8"; "8"] in
        let c = run ["android"; "read"; "media/photos/big.txt"; "16"; "8"] in
        check "three separate processes reassemble the file"
          ~why:(fun () -> Printf.sprintf "%S %S %S" a b c)
          (a ^ b ^ c = fixture);
        check "a range starting mid-chunk is served from its own offset"
          (run ["android"; "read"; "media/photos/big.txt"; "4"; "12"]
          = String.sub fixture 4 12);

        case "a read past the content is short, never padded";
        check "a range straddling the end stops at it"
          (run ["android"; "read"; "media/photos/big.txt"; "16"; "64"]
          = String.sub fixture 16 8);
        check "a range wholly past the end is empty"
          (run ["android"; "read"; "media/photos/big.txt"; "999"; "8"] = "");

        case "metadata answers the way the socket did";
        let stat = run ["android"; "stat"; "media/photos/big.txt"] in
        check "stat names the item by reference"
          ~why:(fun () -> stat)
          (json_field "ref" stat <> None && json_field "parentRef" stat <> None);
        check "stat reports it published"
          ~why:(fun () -> stat)
          (json_field "isUploaded" stat = Some "true");
        let missing = run ["android"; "stat"; "media/photos/nope.txt"] in
        check "a missing key is a coded refusal, not a hang"
          ~why:(fun () -> missing)
          (json_field "ok" missing = Some "false"
          && json_field "code" missing = Some "\"not_found\"");

        case "a file is created empty, and read back whole";
        check "create answers ok"
          (json_field "ok" (run ["android"; "create"; "media/photos/new.txt"])
          = Some "true");
        let created = run ["android"; "stat"; "media/photos/new.txt"] in
        check "a created file is empty"
          ~why:(fun () -> created)
          (json_field "size" created = Some "0");
        let dest = Filename.concat root "fetched.bin" in
        ignore (run ["android"; "fetch"; "media/photos/big.txt"; dest]);
        check "fetch assembles the whole content into a file"
          ~why:(fun () -> string_of_int (String.length (read_file dest)))
          (read_file dest = fixture);

        case "the namespace verbs move and remove";
        ignore
          (run
             [
               "android";
               "rename";
               "media/photos/big.txt";
               "media/photos/moved.txt";
             ]);
        let after = run ["android"; "list"; "media/photos/"] in
        check "a renamed file is listed under its new name"
          ~why:(fun () -> after)
          (json_field "name" after = Some "\"moved.txt\"");
        ignore (run ["android"; "delete"; "media/photos/moved.txt"]);
        ignore (run ["android"; "rmdir"; "media/photos/"]);
        let empty = run ["android"; "list"; "media/"] in
        check "the domain is empty again"
          ~why:(fun () -> empty)
          (json_field "items" empty = Some "[]");

        case "the report needs no daemon to answer";
        let status = run ["android"; "status"] in
        let mentions needle =
          let n = String.length needle and h = String.length status in
          let rec at i =
            i + n <= h && (String.sub status i n = needle || at (i + 1))
          in
          at 0
        in
        check "status names this frontend and its domain"
          ~why:(fun () -> status)
          (mentions "Frontend android" && mentions "Domain media");

        (* A verb nobody drives here is a verb nothing proves, and the list is
           the frontend's own rather than one kept in step by hand. *)
        let registered =
          List.concat_map
            (fun (name, _group, commands) ->
              if name = "android" then
                List.map
                  (fun (c : Frontend.command) -> c.Frontend.verb)
                  commands
              else [])
            (Frontend.entries ())
        in
        let missing =
          List.filter (fun v -> not (Hashtbl.mem exercised v)) registered
        in
        check "every registered android verb is exercised here"
          ~why:(fun () ->
            Printf.sprintf "%d verb(s) untested: %s" (List.length missing)
              (String.concat ", " missing))
          (registered <> [] && missing = []);

        report ~expected:19 ()
