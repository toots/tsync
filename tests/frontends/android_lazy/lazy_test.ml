(* Browsing a domain this client has never synced.

   Spawned like the other android test, and for the same reason: the claim is
   about what one process finds on disk when it starts, so an in-process check
   would pass on a client that only works once something else filled the mirror.

   The mirror is wiped between the writes that publish content and the reads
   that find it again, which is what a device that has only ever browsed looks
   like. What each case records is the listing and the mirror beside it: the
   second is where laziness shows, since a walk that fetched more than it was
   asked for still answers the first correctly. *)

let root = Scratch.dir "android_lazy"
let store = Filename.concat root "store"

(* One client that publishes and then browses, and one standing in for another
   device changing the domain underneath it. *)
let browsing = Filename.concat root "browsing"
let other = Filename.concat root "other"
let case name = Printf.printf "\n=== %s\n" name
let line fmt = Printf.printf ("  " ^^ fmt ^^ "\n%!")
let sh fmt = Printf.ksprintf (fun cmd -> ignore (Sys.command cmd)) fmt

let binary =
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
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

(* Folder ids are minted rather than derived, so each run spells them
   differently; the one this test names is replaced wherever it appears. *)
let seen = ref []

let replace ~needle ~by s =
  let n = String.length needle in
  let buf = Buffer.create (String.length s) in
  let rec go i =
    if i >= String.length s then Buffer.contents buf
    else if i + n <= String.length s && String.sub s i n = needle then begin
      Buffer.add_string buf by;
      go (i + n)
    end
    else begin
      Buffer.add_char buf s.[i];
      go (i + 1)
    end
  in
  go 0

(* Every mtime here comes from the clock at write time, which is the one field
   no fixture can pin; zero is the directories' own and stays visible. *)
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
          | Some v when v = 0. -> value
          | _ -> "<clock>");
      go !stop
    end
    else begin
      Buffer.add_char buf s.[i];
      go (i + 1)
    end
  in
  go 0

let scrub s =
  scrub_clock
    (List.fold_left (fun s (id, by) -> replace ~needle:id ~by s) s !seen)

let mirror ~cache =
  let dir = Filename.concat cache "media/manifests" in
  let out = Filename.concat root "mirror.txt" in
  (* Byte order, not the machine's collation: this listing is compared against a
     committed snapshot, and a locale that ignores the leading dot of
     [.tsync-dir] files it after [pic.txt] rather than before. *)
  sh "find %s -type f 2>/dev/null | sed 's|%s/||' | LC_ALL=C sort > %s"
    (Filename.quote dir) dir (Filename.quote out);
  match read_file out with "" -> "(empty)" | s -> String.trim s

let () =
  match binary with
    | None ->
        print_endline "no tsync binary found";
        exit 1
    | Some tsync ->
        let where home = Android_home.paths ~tsync ~home ~scratch:root in
        let config home =
          let path = (where home).Android_home.config in
          sh "mkdir -p %s" (Filename.quote (Filename.dirname path));
          write_file path
            (Printf.sprintf
               {|{ "name": "test",
  "domains": [ { "name": "media", "versioning": true, "symlinks": "skip",
    "maxCache": "1G", "chunkSize": 64, "cacheChunkSize": 64,
    "frontends": ["android"],
    "backends": [ { "type": "local", "name": "store", "role": "main", "path": %S } ] } ] }|}
               store)
        in
        sh "mkdir -p %s %s %s" (Filename.quote store) (Filename.quote browsing)
          (Filename.quote other);
        config browsing;
        config other;

        let browsing_cache = (where browsing).Android_home.cache in
        let run home args =
          let out = Filename.concat root "reply.json" in
          sh "%s %s android %s > %s 2>/dev/null" (Android_home.env ~home)
            (Filename.quote tsync) args (Filename.quote out);
          String.trim (read_file out)
        in
        let ref_of reply name =
          let needle = Printf.sprintf "\"name\":\"%s\"" name in
          let tag = "\"ref\":\"" in
          let rec find i =
            if i + String.length needle > String.length reply then None
            else if String.sub reply i (String.length needle) = needle then (
              let rec back j =
                if j < 0 then None
                else if
                  j + String.length tag <= String.length reply
                  && String.sub reply j (String.length tag) = tag
                then Some (j + String.length tag)
                else back (j - 1)
              in
              back i)
            else find (i + 1)
          in
          match find 0 with
            | None -> None
            | Some from ->
                let stop = String.index_from reply from '"' in
                Some (String.sub reply from (stop - from))
        in

        ignore (run browsing "mkdir root photos");
        let photos =
          match ref_of (run browsing "list root") "photos" with
            | Some r -> r
            | None ->
                print_endline "photos was never created";
                exit 1
        in
        let id = String.sub photos 2 (String.length photos - 2) in
        seen := [(id, "<photos>")];
        write_file (Filename.concat root "body.txt") "hello-world-contents";
        ignore
          (run browsing
             (Printf.sprintf "write-whole %s pic.txt %s" photos
                (Filename.quote (Filename.concat root "body.txt"))));

        case "a mirror wiped to nothing";
        sh "rm -rf %s %s"
          (Filename.quote (Filename.concat browsing_cache "media/manifests"))
          (Filename.quote (Filename.concat browsing_cache "media/folders"));
        line "mirror: %s" (mirror ~cache:browsing_cache);

        case "the root lists without ever having synced";
        line "%s" (scrub (run browsing "list root"));
        (* Only the folder browsed is here: its contents were not asked for. *)
        line "mirror: %s" (scrub (mirror ~cache:browsing_cache));

        case "descending fetches that folder, and only then";
        line "%s" (scrub (run browsing (Printf.sprintf "list %s" photos)));
        line "mirror: %s" (scrub (mirror ~cache:browsing_cache));

        case "a file another device removed stops being listed, and is pruned";
        ignore (run other "list root");
        ignore (run other (Printf.sprintf "list %s" photos));
        line "the other device deletes it: %s"
          (scrub (run other (Printf.sprintf "delete f:%s/pic.txt" id)));
        line "%s" (scrub (run browsing (Printf.sprintf "list %s" photos)));
        line "mirror: %s" (scrub (mirror ~cache:browsing_cache));

        case "a staged file survives the pull that does not know about it";
        line "created: %s"
          (scrub (run browsing (Printf.sprintf "create %s draft.txt" photos)));
        line "%s" (scrub (run browsing (Printf.sprintf "list %s" photos)))
