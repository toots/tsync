(* Behavioral snapshot of the Android frontend's command surface, driven the way
   the app drives it: one process per call.

   Spawning is the point. Every other test of these operations runs them in one
   process, where the caches, the staged manifests and the Lwt loop all persist
   -- exactly the state this design claims not to need, so an in-process check
   would pass on a frontend that only works as a daemon.

   What is recorded is each reply in full, because the reply is the contract: a
   client reads these field names, and a snapshot of the whole object is what
   notices one of them changing spelling or going missing. *)

let root = Scratch.dir "android"
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

(* Spelled only to be refused: the daemon names items by reference. *)
let photos_key = domain_root ^ "photos/"

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
  match open_in_bin path with
    | exception Sys_error _ -> "<no such file>"
    | ic ->
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
let with_home = Android_home.env ~home

(* stderr carries the log, which the snapshot rule discards: what a caller parses
   is stdout and nothing else. *)
let invoke args =
  (match args with
    | "android" :: verb :: _ -> Hashtbl.replace exercised verb ()
    | _ -> ());
  let out = Filename.concat root "out.bin" in
  let errors = Filename.concat root "err.txt" in
  let quoted = List.map Filename.quote (Option.get binary :: args) in
  let status =
    Sys.command
      (Printf.sprintf "%s %s > %s 2> %s" with_home (String.concat " " quoted)
         (Filename.quote out) (Filename.quote errors))
  in
  (* Only when something went wrong: a backtrace names paths and line numbers,
     which no snapshot could hold, and on a good run there is nothing to say. *)
  if status <> 0 then begin
    line "exited %d" status;
    List.iter
      (fun l -> line "  ! %s" (scrub l))
      (String.split_on_char '\n' (String.trim (read_file errors)))
  end;
  read_file out

let config_path () =
  (Android_home.paths ~tsync:(Option.get binary) ~home ~scratch:root)
    .Android_home.config

(* Entries come back in readdir order, which is the filesystem's and differs
   between one and another; sorting is what makes a listing something a snapshot
   can hold. Everything else about the reply is left exactly as it arrived. *)
let sort_items reply =
  match Yojson.Safe.from_string reply with
    | `Assoc fields when List.mem_assoc "items" fields ->
        let name = function
          | `Assoc entry -> (
              match List.assoc_opt "name" entry with
                | Some (`String n) -> n
                | _ -> "")
          | _ -> ""
        in
        Yojson.Safe.to_string
          (`Assoc
             (List.map
                (fun (k, v) ->
                  match (k, v) with
                    | "items", `List items ->
                        ( k,
                          `List
                            (List.stable_sort
                               (fun a b -> compare (name a) (name b))
                               items) )
                    | _ -> (k, v))
                fields))
    | _ | (exception _) -> reply

(* A client learns a folder's reference by listing its parent, ids being minted
   by the daemon: the same walk the picker does. *)
let child_ref parent name =
  let items =
    match Yojson.Safe.from_string (invoke ["android"; "list"; parent]) with
      | `Assoc fields -> (
          match List.assoc_opt "items" fields with
            | Some (`List l) -> l
            | _ -> [])
      | _ -> []
  in
  let named = function
    | `Assoc e -> List.assoc_opt "name" e = Some (`String name)
    | _ -> false
  in
  match List.find_opt named items with
    | Some (`Assoc e) -> (
        match List.assoc_opt "ref" e with
          | Some (`String r) -> r
          | _ -> failwith ("no ref for " ^ name))
    | _ -> failwith ("no child " ^ name ^ " under " ^ parent)

(* A verb answering in JSON: the call, then the whole reply. *)
let json args =
  line "%s" (scrub (String.concat " " (List.tl args)));
  let reply = String.trim (invoke args) in
  line "  %s" (scrub (sort_items reply));
  reply

(* A ranged read, shown as what landed in the destination. *)
let ranged args ~dest ~offset ~length =
  ignore (json (args @ [dest; string_of_int offset; string_of_int length]));
  let all = read_file dest in
  let got =
    if offset >= String.length all then ""
    else String.sub all offset (min length (String.length all - offset))
  in
  line "  dest[%d,%d) = %S" offset (offset + String.length got) got

(* The one number a caller has to read rather than display: how many bytes
   follow the header. *)
let framed_length reply =
  let field = "\"length\":" in
  let n = String.length field and h = String.length reply in
  let rec at i =
    if i + n > h then 0
    else if String.sub reply i n = field then (
      let stop = ref (i + n) in
      while !stop < h && reply.[!stop] >= '0' && reply.[!stop] <= '9' do
        incr stop
      done;
      int_of_string (String.sub reply (i + n) (!stop - i - n)))
    else at (i + 1)
  in
  at 0

(* Drives the session the way the provider does: one process, a size line, then
   a header and that many bytes per request. *)
let session_ranges key ranges =
  Hashtbl.replace exercised "open" ();
  let exe = Option.get binary in
  let cmd =
    Printf.sprintf "%s %s android open %s" with_home (Filename.quote exe)
      (Filename.quote key)
  in
  let out, inp = Unix.open_process cmd in
  let header = input_line out in
  line "open %s" (scrub header);
  let served =
    List.map
      (fun (offset, length) ->
        Printf.fprintf inp "%d %d\n" offset length;
        flush inp;
        let reply = input_line out in
        let count = framed_length reply in
        let body = really_input_string out count in
        (offset, length, body))
      ranges
  in
  close_out inp;
  ignore (Unix.close_process (out, inp));
  served

let staged contents =
  let path = Filename.concat root "staged.bin" in
  write_file path contents;
  Unix.utimes path fixed_mtime fixed_mtime;
  path

let snapshot () =
  match binary with
    | None ->
        print_endline
          "no tsync binary found; the generated rule should depend on it";
        exit 1
    | Some _ ->
        sh "mkdir -p %s %s" (Filename.quote home) (Filename.quote store);
        let config = config_path () in
        sh "mkdir -p %s" (Filename.quote (Filename.dirname config));
        write_file config
          (Printf.sprintf
             {|{ "name": "test",
  "domains": [ { "name": "media", "versioning": true, "symlinks": "skip",
    "maxCache": "1G", "chunkSize": %d, "cacheChunkSize": %d,
    "frontends": ["android"],
    "backends": [ { "type": "local", "name": "store", "role": "main", "path": %S } ] } ] }|}
             chunk_size chunk_size store);

        case "a directory is made, then seen";
        ignore (json ["android"; "mkdir"; "root"; "photos"]);
        ignore (json ["android"; "list"; "root"]);
        let photos = child_ref "root" "photos" in
        (* The reference a folder answers to has to be the one its children give
           as their parent. *)
        ignore (json ["android"; "stat"; photos]);
        ignore (json ["android"; "stat"; "root"]);

        case "a whole body is adopted by rename";
        let staging = staged fixture in
        ignore (json ["android"; "write-whole"; photos; "big.txt"; staging]);
        line "staging file still there: %b" (Sys.file_exists staging);
        let big = child_ref photos "big.txt" in
        ignore (json ["android"; "stat"; big]);

        case "ranges, each served by its own process, reassemble the file";
        (* Nothing is held between calls, so three processes writing a range
           each into one file leave it whole. *)
        let dest = Filename.concat root "ranges.bin" in
        List.iter
          (fun offset ->
            ranged ["android"; "read"; big] ~dest ~offset ~length:8)
          [0; 8; 16];
        line "reassembled = %S" (read_file dest);
        ranged ["android"; "read"; big]
          ~dest:(Filename.concat root "mid.bin")
          ~offset:4 ~length:12;

        case "a read past the content is short, never padded";
        ranged ["android"; "read"; big]
          ~dest:(Filename.concat root "tail.bin")
          ~offset:16 ~length:64;
        ranged ["android"; "read"; big]
          ~dest:(Filename.concat root "past.bin")
          ~offset:99 ~length:8;

        case "a reference that is not there is a coded refusal";
        ignore (json ["android"; "stat"; "f:.tsync-root/nope.txt"]);
        ignore (json ["android"; "list"; "d:nowhere"]);
        (* A storage key is no reference at all, whatever it names. *)
        ignore (json ["android"; "stat"; photos_key]);

        case "a created file is empty until something is written to it";
        ignore (json ["android"; "create"; photos; "new.txt"]);
        let fresh = child_ref photos "new.txt" in
        ignore (json ["android"; "stat"; fresh]);

        case "the whole content, assembled into a file for editing in place";
        let dest = Filename.concat root "fetched.bin" in
        ignore (json ["android"; "fetch"; big; dest]);
        line "fetched = %S" (read_file dest);

        case "what of the file is on this device";
        ignore (json ["android"; "residency"; big]);

        case "a folder is read a page at a time, resumed by name";
        ignore (json ["android"; "list"; photos; ""; "1"]);
        ignore (json ["android"; "list"; photos; "big.txt"; "1"]);

        case "a link where no backend can hold a share";
        ignore (json ["android"; "share"; big]);

        case "one process serves every range of an open file";
        (* The reason it exists: reads in one process are sequential to
           lib/content/data.ml, which is what lets it fetch ahead of them. *)
        let served = session_ranges big [(0, 8); (8, 8); (16, 8); (99, 8)] in
        List.iter
          (fun (o, l, body) ->
            line "range %d+%d -> %d %S" o l (String.length body) body)
          served;

        case "the namespace verbs move and remove";
        ignore (json ["android"; "rename"; big; photos; "moved.txt"]);
        ignore (json ["android"; "list"; photos]);
        ignore (json ["android"; "delete"; child_ref photos "moved.txt"]);
        ignore (json ["android"; "delete"; fresh]);
        ignore (json ["android"; "rmdir"; photos]);
        ignore (json ["android"; "list"; "root"]);

        case "the report answers with no daemon to ask";
        (* Only the lines that do not describe this machine: the rest of the
           report is uptime, cpu, memory and paths. *)
        let report = invoke ["android"; "status"] in
        String.split_on_char '\n' report
        |> List.iter (fun l ->
            let keep =
              List.exists
                (fun prefix ->
                  String.length l >= String.length prefix
                  && String.sub l 0 (String.length prefix) = prefix)
                ["Domain media"; "  settings"; "  concurrency"]
            in
            if keep then line "%s" (scrub (String.trim l)));

        case "every verb the frontend registers is driven above";
        Tsync_android_frontend.Android_frontend.register ();
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

(* Printed rather than raised: the rule discards stderr and keeps stdout, so an
   exception that escapes here leaves no output at all and a build that says
   only "exited 2". Exiting zero puts it in the diff instead, where it can be
   read. *)
let () =
  try snapshot ()
  with e ->
    Printf.printf "\nuncaught: %s\n" (Printexc.to_string e);
    exit 0
