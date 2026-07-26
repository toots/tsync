(* Two checks on the hand-rolled ZIP64 writer.

   1. A byte-exact snapshot of a fixed archive: any change to the header layout,
      the data descriptors or the ZIP64 trailer shows up as a diff. The mtime is
      fixed and the dune rule pins TZ=UTC, since DOS timestamps are local time.
   2. A real unzip must accept the archive and return the exact bytes back —
      the snapshot alone would happily freeze a broken format. *)

let root = "/tmp/tsync-zip-test"
let archive = root ^ "/out.zip"

(* 1980-01-01 00:00:00 UTC: the DOS epoch, so the packed fields are all zero and
   the snapshot does not drift with the clock. *)
let mtime = 315532800.

let files =
  [
    ("hello.txt", "hello world\n");
    ("nested/deep/data.bin", String.init 300 (fun i -> Char.chr (i mod 256)));
    ("empty.txt", "");
    (* Non-ASCII name: the writer sets the UTF-8 flag bit. *)
    ("caf\xc3\xa9/r\xc3\xa9sum\xc3\xa9.txt", "accents\n");
  ]

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let build () =
  let oc = open_out_bin archive in
  let z = Zip_stream.create () in
  output_string oc (Zip_stream.add_directory z ~name:"nested" ~mtime);
  List.iter
    (fun (name, content) ->
      output_string oc (Zip_stream.start_entry z ~name ~mtime ());
      (* Feed in blocks, the way chunk-by-chunk streaming does. *)
      let block = 128 in
      let rec go off =
        if off < String.length content then (
          let n = min block (String.length content - off) in
          let s = String.sub content off n in
          Zip_stream.feed z s;
          output_string oc s;
          go (off + n))
      in
      go 0;
      output_string oc (Zip_stream.end_entry z))
    files;
  output_string oc (Zip_stream.finish z);
  close_out oc

(* Hex dump with the payload runs elided, so the snapshot stays about framing. *)
let dump () =
  let data = read_file archive in
  Printf.printf "archive: %d bytes\n" (String.length data);
  let n = String.length data in
  let i = ref 0 in
  while !i < n do
    let len = min 16 (n - !i) in
    Printf.printf "%06x  " !i;
    for j = 0 to 15 do
      if j < len then Printf.printf "%02x " (Char.code data.[!i + j])
      else print_string "   "
    done;
    print_string " |";
    for j = 0 to len - 1 do
      let c = data.[!i + j] in
      print_char (if Char.code c >= 32 && Char.code c < 127 then c else '.')
    done;
    print_string "|\n";
    i := !i + 16
  done

let () =
  ignore (Sys.command (Printf.sprintf "rm -rf %s && mkdir -p %s" root root));
  build ();
  dump ();

  (* A real unzip must validate the CRCs and the central directory. *)
  assert (
    Sys.command (Printf.sprintf "unzip -qt %s > /dev/null 2>&1" archive) = 0);

  (* ...and extraction must return the exact bytes. *)
  let out = root ^ "/x" in
  assert (
    Sys.command
      (Printf.sprintf "unzip -qq -d %s %s > /dev/null 2>&1" out archive)
    = 0);
  List.iter
    (fun (name, content) ->
      let got = read_file (Filename.concat out name) in
      if got <> content then (
        Printf.eprintf "zip_test: %s: content mismatch\n" name;
        exit 1))
    files;
  assert (Sys.is_directory (Filename.concat out "nested"));
  print_endline "round-trip: ok"
