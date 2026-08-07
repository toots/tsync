(* What the menu bar gets to draw beside a file it is uploading.

   The bodies here are named the way a staged one is — by uuid, with no
   extension — so what is exercised is exactly the case QuickLook cannot type on
   its own. *)

let root = "/tmp/tsync-preview-test"
let scratch = Filename.concat root "previews"

(* An 8x8 PNG, inline so the test needs nothing on disk to start from. *)
let tiny_png =
  "\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\008\000\000\000\008\008\002\000\000\000\075\109\041\220\000\000\000\009\112\072\089\115\000\000\000\001\000\000\000\001\000\079\037\196\214\000\000\000\070\073\068\065\084\120\156\157\142\193\013\192\048\012\002\057\041\131\101\180\116\179\118\050\098\252\168\250\201\167\247\192\088\216\018\072\178\132\091\241\235\135\026\099\074\077\180\093\130\186\203\242\001\024\058\240\035\168\002\122\088\025\147\170\051\117\165\231\125\252\216\053\192\024\027\146\197\099\078\000\000\000\000\073\069\078\068\174\066\096\130"

let write body contents =
  let path = Filename.concat root body in
  let out = open_out_bin path in
  output_string out contents;
  close_out out;
  path

let describe label ~name path =
  let open Lwt.Syntax in
  let+ picture = Preview.of_file ~scratch ~name path in
  match picture with
    | None -> Printf.printf "%-22s -> none\n" label
    | Some picture ->
        (* The bytes are QuickLook's and not worth pinning down; that it made a
           PNG at all is the claim. *)
        let png = String.length picture > 8 && String.sub picture 1 3 = "PNG" in
        Printf.printf "%-22s -> %s\n" label (if png then "png" else "other")

let () =
  Lwt_main.run
    (let open Lwt.Syntax in
     (try Unix.mkdir root 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
     let image = write "9d4181f472e5e18d" tiny_png in
     let text = write "96a753cca01c2695" "plain text, whatever it is called" in
     let* () = describe "image, named .png" ~name:"photo.png" image in
     (* The name only types the file; it cannot make one into an image. *)
     let* () = describe "text, named .png" ~name:"liar.png" text in
     let* () = describe "text, named .txt" ~name:"notes.txt" text in
     (* A body that finished uploading between the listing and the request. *)
     describe "missing body" ~name:"gone.png"
       (Filename.concat root "0000000000000000"))
