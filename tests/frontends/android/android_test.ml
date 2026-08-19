(* Behavioral snapshot of the Android frontend's command surface, driven the way
   the app drives it: one process per call.

   Spawning is the point. Every other test of these operations runs them in one
   process, where the caches, the staged manifests and the Lwt loop all persist
   -- exactly the state this design claims not to need, so an in-process check
   would pass on a frontend that only works as a daemon.

   What is recorded is each reply in full, because the reply is the contract: a
   client reads these field names, and a snapshot of the whole object is what
   notices one of them changing spelling or going missing. *)

let root = Filename.temp_dir "tsync-android" ""
let home = Filename.concat root "home"
let store = Filename.concat root "store"

(* Chunks of 8 bytes, so the 24-byte fixture spans three and a ranged read
   crosses a boundary. *)
let chunk_size = 8
let fixture = "0123456789ABCDEFghijklmn"

(* Every published mtime comes from the staged file's own, so fixing that fixes
   the one field in a reply that would otherwise differ per run. *)
let fixed_mtime = 1_400_000_000.

(* What the app addresses items by: Conf.domain_prefix, spelled the same way in
   Keys.root on the Kotlin side. A bare domain name would take a lenient path
   that strips no prefix and answers about a different key. *)
let domain_root = "tsync/media/manifests/"
let photos = domain_root ^ "photos/"

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

let sh fmt = Printf.ksprintf (fun cmd -> ignore (Sys.command cmd)) fmt
let case name = Printf.printf "\n=== %s\n" name
let line fmt = Printf.printf ("  " ^^ fmt ^^ "\n%!")

(* [create] stamps a staged manifest with the clock, which is the one mtime no
   fixture can pin. Every other one is either zero or {!fixed_mtime}, and those
   stay visible: that a staged file's own time reaches the manifest is the whole
   channel by which a photo keeps its capture time. *)
let scrub_clock s =
  let field = "\"mtime\":" in
  let n = String.length field and h = String.length s in
  let buf = Buffer.create h in
  let rec go i =
    if i >= h then Buffer.contents buf
    else if i + n <= h && String.sub s i n = field then begin
      let stop = ref (i + n) in
      while
        !stop < h
        &&
          match s.[!stop] with
          | '0' .. '9' | '.' | '-' | 'e' -> true
          | _ -> false
      do
        incr stop
      done;
      let value = String.sub s (i + n) (!stop - i - n) in
      Buffer.add_string buf field;
      Buffer.add_string buf
        (match float_of_string_opt value with
          | Some v when v = 0. || v = fixed_mtime -> value
          | _ -> "<clock>");
      go !stop
    end
    else begin
      Buffer.add_char buf s.[i];
      go (i + 1)
    end
  in
  go 0

(* Folder ids are minted rather than derived from the path, so each run spells
   them differently. Only the ones a reference names are numbered: a directory's
   etag is its own id and follows, while a file's is a content hash, which is
   stable and worth reading. *)
let seen_ids : (string, string) Hashtbl.t = Hashtbl.create 8
let is_hex c = match c with '0' .. '9' | 'a' .. 'f' -> true | _ -> false

let hex_at s i =
  i + 16 <= String.length s
  &&
  let rec all j = j = 16 || (is_hex s.[i + j] && all (j + 1)) in
  all 0

(* Learn the ids from the reference forms, then replace those and nothing else. *)
let scrub_ids s =
  String.iteri
    (fun i c ->
      if
        (c = 'd' || c = 'f')
        && i + 1 < String.length s
        && s.[i + 1] = ':'
        && hex_at s (i + 2)
      then (
        let id = String.sub s (i + 2) 16 in
        if not (Hashtbl.mem seen_ids id) then
          Hashtbl.replace seen_ids id
            (Printf.sprintf "<id%d>" (Hashtbl.length seen_ids + 1))))
    s;
  let h = String.length s in
  let buf = Buffer.create h in
  let rec go i =
    if i >= h then Buffer.contents buf
    else if hex_at s i && Hashtbl.mem seen_ids (String.sub s i 16) then begin
      Buffer.add_string buf (Hashtbl.find seen_ids (String.sub s i 16));
      go (i + 16)
    end
    else begin
      Buffer.add_char buf s.[i];
      go (i + 1)
    end
  in
  go 0

(* The scratch directory is named after the process, so it appears in a reply
   that echoes a path back. *)
let scrub s =
  let replace haystack needle by =
    let n = String.length needle and h = String.length haystack in
    let buf = Buffer.create h in
    let rec go i =
      if i >= h then Buffer.contents buf
      else if i + n <= h && String.sub haystack i n = needle then begin
        Buffer.add_string buf by;
        go (i + n)
      end
      else begin
        Buffer.add_char buf haystack.[i];
        go (i + 1)
      end
    in
    go 0
  in
  scrub_ids
    (scrub_clock
       (replace (replace s root "<root>") (Unix.gethostname ()) "<host>"))

let exercised : (string, unit) Hashtbl.t = Hashtbl.create 16

(* stderr carries the log, which the snapshot rule discards: what a caller parses
   is stdout and nothing else. *)
let invoke args =
  (match args with
    | "android" :: verb :: _ -> Hashtbl.replace exercised verb ()
    | _ -> ());
  let out = Filename.concat root "out.bin" in
  let quoted = List.map Filename.quote (Option.get binary :: args) in
  sh "HOME=%s %s > %s 2>/dev/null" (Filename.quote home)
    (String.concat " " quoted) (Filename.quote out);
  read_file out

(* A verb answering in JSON: the call, then the whole reply. *)
let json args =
  line "%s" (scrub (String.concat " " (List.tl args)));
  let reply = String.trim (invoke args) in
  line "  %s" (scrub reply);
  reply

(* A verb answering in bytes: how many came back, and what they were. *)
let bytes args =
  line "%s" (String.concat " " (List.tl args));
  let out = invoke args in
  line "  %d bytes = %S" (String.length out) out;
  out

let staged contents =
  let path = Filename.concat root "staged.bin" in
  write_file path contents;
  Unix.utimes path fixed_mtime fixed_mtime;
  path

let () =
  match binary with
    | None ->
        print_endline
          "no tsync binary found; the generated rule should depend on it";
        exit 1
    | Some _ ->
        sh "mkdir -p %s %s"
          (Filename.quote (Filename.concat home ".config/tsync"))
          (Filename.quote store);
        write_file
          (Filename.concat home ".config/tsync/config.json")
          (Printf.sprintf
             {|{ "name": "test",
  "domains": [ { "name": "media", "versioning": true, "symlinks": "skip",
    "maxCache": "1G", "chunkSize": %d, "cacheChunkSize": %d,
    "frontends": ["android"],
    "backends": [ { "type": "local", "name": "store", "role": "main", "path": %S } ] } ] }|}
             chunk_size chunk_size store);

        case "a directory is made, then seen";
        ignore (json ["android"; "mkdir"; photos]);
        ignore (json ["android"; "list"; domain_root]);

        case "a whole body is adopted by rename";
        let staging = staged fixture in
        ignore (json ["android"; "write-whole"; photos ^ "big.txt"; staging]);
        line "staging file still there: %b" (Sys.file_exists staging);
        ignore (json ["android"; "stat"; photos ^ "big.txt"]);

        case "ranges, each served by its own process, reassemble the file";
        (* Nothing is held between calls, so three processes reading a range
           each is the same as one reading all of it. *)
        let a = bytes ["android"; "read"; photos ^ "big.txt"; "0"; "8"] in
        let b = bytes ["android"; "read"; photos ^ "big.txt"; "8"; "8"] in
        let c = bytes ["android"; "read"; photos ^ "big.txt"; "16"; "8"] in
        line "reassembled = %S" (a ^ b ^ c);
        ignore (bytes ["android"; "read"; photos ^ "big.txt"; "4"; "12"]);

        case "a read past the content is short, never padded";
        ignore (bytes ["android"; "read"; photos ^ "big.txt"; "16"; "64"]);
        ignore (bytes ["android"; "read"; photos ^ "big.txt"; "99"; "8"]);

        case "a key that is not there is a coded refusal";
        ignore (json ["android"; "stat"; photos ^ "nope.txt"]);
        ignore (json ["android"; "list"; domain_root ^ "nowhere/"]);

        case "a created file is empty until something is written to it";
        ignore (json ["android"; "create"; photos ^ "new.txt"]);
        ignore (json ["android"; "stat"; photos ^ "new.txt"]);

        case "the whole content, assembled into a file for editing in place";
        let dest = Filename.concat root "fetched.bin" in
        ignore (json ["android"; "fetch"; photos ^ "big.txt"; dest]);
        line "fetched = %S" (read_file dest);

        case "the namespace verbs move and remove";
        ignore
          (json ["android"; "rename"; photos ^ "big.txt"; photos ^ "moved.txt"]);
        ignore (json ["android"; "list"; photos]);
        ignore (json ["android"; "delete"; photos ^ "moved.txt"]);
        ignore (json ["android"; "delete"; photos ^ "new.txt"]);
        ignore (json ["android"; "rmdir"; photos]);
        ignore (json ["android"; "list"; domain_root]);

        case "the report answers with no daemon to ask";
        (* Only the lines that do not describe this machine: the rest of the
           report is cpu, memory and paths. *)
        let report = invoke ["android"; "status"] in
        String.split_on_char '\n' report
        |> List.iter (fun l ->
            let keep =
              List.exists
                (fun prefix ->
                  String.length l >= String.length prefix
                  && String.sub l 0 (String.length prefix) = prefix)
                [
                  "Frontend android";
                  "Domain media";
                  "  read-only";
                  "  versioning";
                ]
            in
            if keep then line "%s" (scrub (String.trim l)));

        case "every verb the frontend registers is driven above";
        (* Asked of the registry rather than kept in step by hand: a verb added
           without a case here changes this line. *)
        let registered =
          List.concat_map
            (fun (name, _group, commands) ->
              if name = "android" then
                List.map
                  (fun (c : Frontend.command) -> c.Frontend.verb)
                  commands
              else [])
            (Frontend.entries ())
          |> List.sort compare
        in
        line "registered: %s" (String.concat " " registered);
        line "untested:   %s"
          (match
             List.filter (fun v -> not (Hashtbl.mem exercised v)) registered
           with
            | [] -> "(none)"
            | missing -> String.concat " " missing);
        sh "rm -rf %s" (Filename.quote root)
