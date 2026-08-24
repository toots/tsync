(* How a store names a folder's children. The hash is rendered so that a change
   to it shows up as what it is: every existing object filed under the old one
   becoming unreachable. *)

let show label s = Printf.printf "%-26s %s\n" label s

(* Rendered without a space so what is shown is the path a folder files its
   children under, which is what a change to the hash would move. *)
let child ~folder_id name =
  Stored_key.to_string (Stored_key.child_key ~prefix:"" ~folder_id name)

let index ~folder_id =
  Stored_key.to_string (Stored_key.index_key ~prefix:"" ~folder_id)

let () =
  let fid = "9f3a1c0428b6d5e7" in
  print_endline "=== the ids that anchor the tree";
  show "root" Stored_key.root_id;
  show "trash" Stored_key.trash_id;
  show "a minted id's shape"
    (Printf.sprintf "%d hex characters" (String.length (Stored_key.new_id ())));
  show "two mints differ"
    (string_of_bool (Stored_key.new_id () <> Stored_key.new_id ()));

  print_endline "\n=== where a child is filed";
  show "img.jpg" (child ~folder_id:fid "img.jpg");
  show "the same name again"
    (string_of_bool
       (child ~folder_id:fid "img.jpg" = child ~folder_id:fid "img.jpg"));
  show "a name needing escaping" (child ~folder_id:fid "a b/c.txt");
  show "under another folder" (child ~folder_id:"0000" "img.jpg");
  show "the folder's index" (index ~folder_id:fid);
  show "the same child, in a space"
    (Stored_key.to_string
       (Stored_key.child_key ~prefix:"tsync/photos/manifests/" ~folder_id:fid
          "img.jpg"));

  print_endline "\n=== what a listing offers";
  List.iter
    (fun (label, key) ->
      Printf.printf "%-26s index=%-5b child=%b\n" label
        (Stored_key.is_index_key key)
        (Stored_key.is_child_object key))
    [
      ("a child", child ~folder_id:fid "img.jpg");
      ("the index", index ~folder_id:fid);
      ("the namespace itself", fid ^ "/");
      ("a write in flight", Filename.temp_path (fid ^ "/abcd"));
    ]
