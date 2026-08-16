(* How an item is named on the wire.

   [parse] is total: a reference arrives from another process, and a malformed one
   must come back as an error rather than take down the request. The forms also
   stay distinguishable from a logical key, both travelling in one protocol. *)

open Check

let () =
  check "the root has its own spelling" (Item_ref.parse "root" = `Root);
  check "a directory is named by id" (Item_ref.parse "d:9f3a" = `Dir "9f3a");
  check "a file is named by parent and leaf"
    (Item_ref.parse "f:9f3a/report.pdf" = `File ("9f3a", "report.pdf"));

  (* One item, one name, or the system believes in two containers. *)
  check "the root id normalises to the root"
    (Item_ref.parse ("d:" ^ Folder.root_id) = `Root);

  (* A leaf name cannot contain "/" but may contain anything else, including the
     characters the scheme itself uses. *)
  check "only the first slash separates"
    (Item_ref.parse "f:9f3a/a/b" = `File ("9f3a", "a/b"));
  check "a colon in a name is just a character"
    (Item_ref.parse "f:9f3a/od:d.txt" = `File ("9f3a", "od:d.txt"));

  check "a storage key stays a key"
    (Item_ref.parse "tsync/dom/manifests/a.txt"
    = `Key "tsync/dom/manifests/a.txt");

  (* Malformed: answered, never raised. *)
  check "a file form with no leaf is bad"
    (Item_ref.parse "f:9f3a" = `Bad "f:9f3a");
  check "a file form with an empty leaf is bad"
    (Item_ref.parse "f:9f3a/" = `Bad "f:9f3a/");
  check "a file form with no parent is bad"
    (Item_ref.parse "f:/a.txt" = `Bad "f:/a.txt");
  check "a bare prefix is not a reference" (Item_ref.parse "d:" = `Key "d:");

  (* Round trip, so a reference handed back names the same thing. *)
  List.iter
    (fun s ->
      check ("round trips: " ^ s) (Item_ref.to_string (Item_ref.parse s) = s))
    ["root"; "d:9f3a"; "f:9f3a/report.pdf"; "tsync/dom/manifests/a.txt"]
