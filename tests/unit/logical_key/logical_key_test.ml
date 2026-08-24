(* The name a domain gives an item. The trailing separator is the wire spelling
   of a folder and nothing else: it is rendered here so that a change to where
   it appears shows up as a change to what these keys are called. *)

module K = Logical_key.Make (struct
  let domain_prefix = "tsync/home/manifests/"
end)

let kind k = match Logical_key.kind k with `File -> "file" | `Dir -> "dir"

let show label k =
  Printf.printf "%-22s %-44s leaf=%-9s %s\n" label
    (Printf.sprintf "%S" (Logical_key.to_string k))
    (Logical_key.leaf k) (kind k)

let attempt label f =
  match f () with
    | s -> Printf.printf "%-22s %s\n" label s
    | exception Invalid_argument _ -> Printf.printf "%-22s refused\n" label

let () =
  let img = K.file "photos/trip/img.jpg" in
  let trip = K.dir "photos/trip" in
  let top = K.file "notes.txt" in

  print_endline "=== how an item is spelled";
  show "a file" img;
  show "a folder" trip;
  show "the root" K.root;
  show "a top-level file" top;

  print_endline "\n=== the path a journal entry records";
  List.iter
    (fun (l, k) -> Printf.printf "%-22s %S\n" l (Logical_key.path k))
    [("a file", img); ("a folder", trip); ("the root", K.root)];

  print_endline "\n=== what an item sits in";
  List.iter
    (fun (l, k) ->
      Printf.printf "%-22s %S\n" l
        (Logical_key.to_string (Logical_key.parent k)))
    [
      ("a file", img);
      ("a folder", trip);
      ("a top-level file", top);
      ("the root", K.root);
    ];

  print_endline "\n=== descending";
  Printf.printf "%-22s %S\n" "into a folder"
    (Logical_key.to_string (Logical_key.file_in trip "img.jpg"));
  Printf.printf "%-22s %S\n" "from the root"
    (Logical_key.to_string (Logical_key.file_in K.root "notes.txt"));
  Printf.printf "%-22s %S\n" "a folder in a folder"
    (Logical_key.to_string (Logical_key.dir_in trip "raw"));

  print_endline "\n=== what a folder offers and a file does not";
  attempt "descend into a file" (fun () ->
      Printf.sprintf "%S" (Logical_key.to_string (Logical_key.file_in img "x")));

  print_endline "\n=== back from the wire";
  List.iter
    (fun s ->
      Printf.printf "%-46s %s\n" (Printf.sprintf "%S" s)
        (match K.rel_of_string s with
          | Some rel -> Printf.sprintf "%S" rel
          | None -> "not this domain's"))
    [
      "tsync/home/manifests/photos/trip/img.jpg";
      "tsync/home/manifests/photos/trip/";
      "tsync/home/manifests/";
      "tsync/work/manifests/img.jpg";
      "img.jpg";
    ];

  print_endline "\n=== two items of one name";
  Printf.printf "%-22s %b\n" "file and folder equal"
    (Logical_key.equal (K.file "photos") (K.dir "photos"));
  Printf.printf "%-22s %b\n" "a leading separator"
    (Logical_key.equal (K.file "/notes.txt") (K.file "notes.txt"))
