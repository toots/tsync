(* The domain driven the way the app drives it: linked in, one Lwt loop, reads
   arriving on threads the runtime never made.

   Spawning is what the other android test proves; this one proves the
   opposite arrangement, where nothing is spawned and the risk moves to thread
   registration and to a loop that outlives every call. *)

external stress : int -> int -> int -> string -> int = "tsync_stress"

let root = Scratch.dir "android_bridge"
let home = Filename.concat root "home"
let store = Filename.concat root "store"
let chunk_size = 64

(* Spans several chunks and several cache groups, so a read crosses boundaries
   and the sequential heuristic has somewhere to run. *)
let fixture = String.init 4096 (fun i -> Char.chr (33 + (i mod 90)))

let sh fmt = Printf.ksprintf (fun cmd -> ignore (Sys.command cmd)) fmt
let line fmt = Printf.printf (fmt ^^ "\n%!")

let binary =
  let rec find dir depth =
    if depth = 0 then None
    else
      let candidate = Filename.concat dir "bin/tsync.exe" in
      if Sys.file_exists candidate then Some candidate
      else find (Filename.dirname dir) (depth - 1)
  in
  find (Sys.getcwd ()) 6

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

(* The reference a listing gives the file, found by the shape of the field
   rather than by parsing: the reply is one line and the test wants one value. *)
let ref_of listing name =
  let needle = Printf.sprintf "\"name\":\"%s\"" name in
  let rec index_from i =
    if i + String.length needle > String.length listing then None
    else if String.sub listing i (String.length needle) = needle then Some i
    else index_from (i + 1)
  in
  match index_from 0 with
    | None -> None
    | Some at -> (
        let tag = "\"ref\":\"" in
        let rec back i =
          if i < 0 then None
          else if
            i + String.length tag <= String.length listing
            && String.sub listing i (String.length tag) = tag
          then Some (i + String.length tag)
          else back (i - 1)
        in
        match back at with
          | None -> None
          | Some from ->
              let stop = String.index_from listing from '"' in
              Some (String.sub listing from (stop - from)))

let () =
  match binary with
    | None ->
        print_endline "no tsync binary found";
        exit 1
    | Some tsync ->
        sh "mkdir -p %s %s" (Filename.quote home) (Filename.quote store);
        (* This one calls in rather than spawning, so the environment it sets is
           the one the runtime reads. *)
        Android_home.adopt ~home;
        let config =
          (Android_home.paths ~tsync ~home ~scratch:root).Android_home.config
        in
        sh "mkdir -p %s" (Filename.quote (Filename.dirname config));
        write_file config
          (Printf.sprintf
             {|{ "name": "test",
  "domains": [ { "name": "media", "versioning": true, "symlinks": "skip",
    "maxCache": "1G", "chunkSize": %d, "cacheChunkSize": %d,
    "frontends": ["android"],
    "backends": [ { "type": "local", "name": "store", "role": "main", "path": %S } ] } ] }|}
             chunk_size chunk_size store);

        let staging = Filename.concat root "staged.bin" in
        write_file staging fixture;
        sh "%s %s android write-whole root big.bin %s >/dev/null"
          (Android_home.env ~home) (Filename.quote tsync)
          (Filename.quote staging);
        let listing = Filename.concat root "listing.json" in
        sh "%s %s android list root > %s" (Android_home.env ~home)
          (Filename.quote tsync) (Filename.quote listing);
        let item =
          let ic = open_in_bin listing in
          let s = really_input_string ic (in_channel_length ic) in
          close_in ic;
          ref_of s "big.bin"
        in
        let item =
          match item with
            | Some r -> r
            | None ->
                print_endline "the fixture was never published";
                exit 1
        in

        (match Tsync_android_jni.Android_jni.boot "" with
          | "" -> line "booted"
          | failure ->
              Printf.printf "boot failed: %s\n" failure;
              exit 1);

        let handle = Tsync_android_jni.Android_jni.opened item in
        if handle < 0 then (
          Printf.printf "open failed: %d\n" handle;
          exit 1);
        line "size matches: %b"
          (Tsync_android_jni.Android_jni.size handle
          = Int64.of_int (String.length fixture));

        (* Enough threads to outnumber anything the app will have reading at
           once, and enough reads each to cross the file several times. *)
        let mismatches = stress 8 handle 64 fixture in
        line "concurrent reads served wrong bytes: %d" mismatches;
        line "close: %d" (Tsync_android_jni.Android_jni.close handle);

        (* A closed handle is the errno path, which is the only way a caller
           hears about anything. *)
        line "read after close: %d"
          (Tsync_android_jni.Android_jni.read handle 0L (Bigstringaf.create 8));
        line "open of a name the domain does not have: %d"
          (Tsync_android_jni.Android_jni.opened "f:0000000000000000/absent")
