(* The framing a listing crosses an http-proxy in.

   A body arrives in whatever pieces the network chose, so a page split across
   two of them, or several pages arriving in one, is the ordinary case. What has
   to hold is that the pages come out whole, in order, exactly once — and that a
   stream which stops early is told apart from one that finished, since a
   listing silently cut short is objects a resync never copies and never
   mentions. *)

open Check

let entry key size = Backend.{ key; size; last_modified = 0. }

let pages =
  [
    [entry "tsync/d/chunks/000/aa" 8; entry "tsync/d/chunks/001/bb" 16];
    [entry "tsync/d/chunks/002/cc" 24];
    [];
    [entry "tsync/d/manifests/a name with spaces.bin" 1];
  ]

let body =
  String.concat "" (List.map Http_proxy.Wire.page_line pages)
  ^ Http_proxy.Wire.done_line

(* Every split of [s] into pieces of [n] bytes, which is what a chunked body is
   without the guarantee that a piece is a line. *)
let pieces n s =
  let rec go i acc =
    if i >= String.length s then List.rev acc
    else (
      let len = min n (String.length s - i) in
      go (i + len) (String.sub s i len :: acc))
  in
  go 0 []

let read body_pieces =
  let r = Http_proxy.Wire.reader () in
  let got = ref [] and terminated = ref false and errors = ref [] in
  List.iter
    (fun piece ->
      List.iter
        (fun line ->
          match Http_proxy.Wire.parse_line line with
            | `Page p -> got := p :: !got
            | `Done -> terminated := true
            | `Error msg -> errors := msg :: !errors)
        (Http_proxy.Wire.feed r piece))
    body_pieces;
  (List.rev !got, !terminated, List.rev !errors, Http_proxy.Wire.rest r)

(* Faithful rather than filtering: framing carries what it is given, and the
   drivers are what decline to send an empty page. *)
let expected = pages

let () =
  print_endline "=== whatever the network does to the boundaries";
  (* 1 splits every line; a prime near the line length lands mid-key and
     mid-number; the whole body in one piece is the case with no split at all. *)
  List.iter
    (fun n ->
      let got, terminated, errors, rest = read (pieces n body) in
      let ok = got = expected && terminated && errors = [] && rest = "" in
      check (Printf.sprintf "pieces of %d byte(s) yield the same pages" n) ok;
      if not ok then
        Printf.printf "    got %d page(s), terminated=%b, rest=%S\n"
          (List.length got) terminated rest)
    [1; 3; 7; 17; 64; String.length body];

  print_endline "\n=== a blank line is not a page";
  let r = Http_proxy.Wire.reader () in
  check "and is dropped rather than parsed" (Http_proxy.Wire.feed r "\n\n" = []);

  print_endline "\n=== a stream that stops early";
  let truncated = String.sub body 0 (String.length body - 20) in
  let _, terminated, _, _ = read (pieces 5 truncated) in
  check "is not mistaken for one that finished" (not terminated);

  print_endline "\n=== a body that ends exactly on its terminator";
  let _, terminated, _, rest = read [body] in
  check "terminates" terminated;
  check "and leaves nothing buffered" (rest = "");

  print_endline "\n=== a failure the status line could not carry";
  let failed =
    Http_proxy.Wire.page_line (List.hd pages)
    ^ Http_proxy.Wire.error_line "the store went away"
  in
  let got, terminated, errors, _ = read (pieces 4 failed) in
  check "the pages before it still arrive" (got = [List.hd pages]);
  check "the failure arrives as a line" (errors = ["the store went away"]);
  check "and the stream is not terminated" (not terminated);

  print_endline "\n=== a key that would break the framing if it could";
  (* Yojson escapes a newline rather than emitting one, which is the whole
     reason a line can delimit a page. *)
  let nasty = [entry "a\nb\tc\"d" 3] in
  let got, _, _, _ = read [Http_proxy.Wire.page_line nasty] in
  check "survives a key holding a newline, a tab and a quote" (got = [nasty]);

  Printf.printf "\n%d check(s), %d failure(s)\n" (checks ()) (failures ());
  report ()
