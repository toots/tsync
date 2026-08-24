(* How an item is named on the wire.

   [parse] is total: a reference arrives from another process, and a malformed one
   must come back as an error rather than take down the request. The forms also
   stay distinguishable from a logical key, both travelling in one protocol. *)

open Check

module Ir = Item_ref.Make (struct
  let domain_prefix = "tsync/dom/manifests/"
end)

module Lk = Logical_key.Make (struct
  let domain_prefix = "tsync/dom/manifests/"
end)

let () =
  check "the root has its own spelling" (Ir.parse "root" = `Root);
  check "a directory is named by id" (Ir.parse "d:9f3a" = `Dir "9f3a");
  check "a file is named by parent and leaf"
    (Ir.parse "f:9f3a/report.pdf" = `File ("9f3a", "report.pdf"));

  (* One item, one name, or the system believes in two containers. *)
  check "the root id normalises to the root"
    (Ir.parse ("d:" ^ Stored_key.root_id) = `Root);

  (* A leaf name cannot contain "/" but may contain anything else, including the
     characters the scheme itself uses. *)
  check "only the first slash separates"
    (Ir.parse "f:9f3a/a/b" = `File ("9f3a", "a/b"));
  check "a colon in a name is just a character"
    (Ir.parse "f:9f3a/od:d.txt" = `File ("9f3a", "od:d.txt"));

  (* A key says what an item is called and not which kind it is, so it is no
     reference at all: whoever holds one holds the mirror that answers that. *)
  check "a storage key is not a reference"
    (Ir.parse "tsync/dom/manifests/a.txt" = `Bad "tsync/dom/manifests/a.txt");
  check "another domain's key is no better"
    (Ir.parse "tsync/other/manifests/a.txt" = `Bad "tsync/other/manifests/a.txt");

  (* Malformed: answered, never raised. *)
  check "a file form with no leaf is bad" (Ir.parse "f:9f3a" = `Bad "f:9f3a");
  check "a file form with an empty leaf is bad"
    (Ir.parse "f:9f3a/" = `Bad "f:9f3a/");
  check "a file form with no parent is bad"
    (Ir.parse "f:/a.txt" = `Bad "f:/a.txt");
  check "a bare prefix is not a reference" (Ir.parse "d:" = `Bad "d:");

  (* Round trip, so a reference handed back names the same thing. *)
  List.iter
    (fun s -> check ("round trips: " ^ s) (Item_ref.to_string (Ir.parse s) = s))
    ["root"; "d:9f3a"; "f:9f3a/report.pdf"; "tsync/dom/manifests/a.txt"]
