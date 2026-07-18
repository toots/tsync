(* Zip entry names are rooted at the shared folder, not the domain root. *)
let dp = "prefix/my domain/"
let name rel key = Share.zip_entry_name ~domain_prefix:dp ~rel key

let () =
  (* Deeply nested share: top-level dir is the shared folder's basename. *)
  let rel = "a/b/c/shared folder" in
  assert (name rel (dp ^ rel ^ "/file.txt") = "shared folder/file.txt");
  (* The shared folder's own directory marker. *)
  assert (name rel (dp ^ rel ^ "/") = "shared folder/");
  (* Nested subfolders keep their structure below the shared root. *)
  assert (name rel (dp ^ rel ^ "/sub/inner.txt") = "shared folder/sub/inner.txt");

  (* Top-level folder (no parent): name starts at the folder. *)
  assert (name "photos" (dp ^ "photos/beach.jpg") = "photos/beach.jpg");

  (* Whole-domain share (rel = ""): entries stay domain-relative. *)
  assert (name "" (dp ^ "anything/x.txt") = "anything/x.txt");

  print_endline "share_test ok"
