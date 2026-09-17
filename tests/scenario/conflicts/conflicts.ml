(* What a peer's op does to one this client has made and not yet published: B
   holds its queues, makes its change, applies A's, then publishes. Each is a
   row of the conflict table, named for it.

   Ops that do not clash end with both clients holding the same tree. Ops that
   clash on a name end with a conflicted copy, or failing that with one side's
   version everywhere. *)

open Test_runner

let conflict name ~setup ~ours ~theirs =
  {
    name;
    steps =
      setup
      @ [A Drain; B Sync; B (Metadata `Paused); B (Uploads `Paused)]
      @ ours @ theirs
      @ [
          A Drain;
          B Sync;
          B (Metadata `Running);
          B (Uploads `Running);
          B Drain;
          A Sync;
          B Sync;
        ];
  }

let write path content = Write { path; content }
let rename src dst = Rename { src; dst }
let file = [A (write "f.txt" "first")]
let folder = [A (Mkdir "d")]

let () =
  run_two_client_scenarios
    [
      (* No clash: a rename over a file this client holds replaces it. *)
      conflict "n1_rename_over_an_existing_file"
        ~setup:(file @ [A (write "g.txt" "replaced")])
        ~ours:[B (rename "f.txt" "g.txt")]
        ~theirs:[];
      (* An edit outlives a delete. *)
      conflict "f1_delete_vs_edit" ~setup:file ~ours:[B (Delete "f.txt")]
        ~theirs:[A (write "f.txt" "edited")];
      conflict "f2_delete_vs_rename" ~setup:file ~ours:[B (Delete "f.txt")]
        ~theirs:[A (rename "f.txt" "h.txt")];
      (* A new file at a removed name is not the one removed. *)
      conflict "f3_delete_vs_rename_onto" ~setup:file ~ours:[B (Delete "f.txt")]
        ~theirs:[A (write "x.txt" "new"); A Drain; A (rename "x.txt" "f.txt")];
      (* An edit follows the file it was made to. *)
      conflict "f4_rename_vs_edit" ~setup:file
        ~ours:[B (rename "f.txt" "g.txt")]
        ~theirs:[A (write "f.txt" "edited")];
      conflict "f5_rename_vs_delete" ~setup:file
        ~ours:[B (rename "f.txt" "g.txt")]
        ~theirs:[A (Delete "f.txt")];
      conflict "f6_rename_vs_rename" ~setup:file
        ~ours:[B (rename "f.txt" "g.txt")]
        ~theirs:[A (rename "f.txt" "h.txt")];
      conflict "f7_rename_vs_create_at_destination" ~setup:file
        ~ours:[B (rename "f.txt" "g.txt")]
        ~theirs:[A (write "g.txt" "theirs")];
      conflict "f8_rename_vs_their_file_moving_off_destination" ~setup:file
        ~ours:[B (rename "f.txt" "g.txt")]
        ~theirs:
          [A (write "g.txt" "theirs"); A Drain; A (rename "g.txt" "h.txt")];
      conflict "f9_edit_vs_edit" ~setup:file
        ~ours:[B (write "f.txt" "ours")]
        ~theirs:[A (write "f.txt" "theirs")];
      (* Removing a folder outlives what a peer adds to it. *)
      conflict "d1_rmdir_vs_add_inside"
        ~setup:(folder @ [A (write "d/a.txt" "a")])
        ~ours:[B (Delete "d/a.txt"); B (Rmdir "d")]
        ~theirs:[A (write "d/x.txt" "added")];
      conflict "d2_rmdir_vs_rename" ~setup:folder ~ours:[B (Rmdir "d")]
        ~theirs:[A (rename "d" "e")];
      conflict "d3_rename_vs_add_inside" ~setup:folder
        ~ours:[B (rename "d" "e")]
        ~theirs:[A (write "d/x.txt" "added")];
      conflict "d4_rename_vs_rename" ~setup:folder
        ~ours:[B (rename "d" "e")]
        ~theirs:[A (rename "d" "f")];
      conflict "d5_rename_vs_mkdir_at_destination" ~setup:folder
        ~ours:[B (rename "d" "e"); B (write "e/ours.txt" "ours")]
        ~theirs:[A (Mkdir "e"); A (write "e/theirs.txt" "theirs")];
      conflict "d6_mkdir_vs_mkdir" ~setup:[]
        ~ours:[B (Mkdir "d"); B (write "d/ours.txt" "ours")]
        ~theirs:[A (Mkdir "d"); A (write "d/theirs.txt" "theirs")];
      conflict "d7_rmdir_vs_rmdir" ~setup:folder ~ours:[B (Rmdir "d")]
        ~theirs:[A (Rmdir "d")];
      conflict "d8_add_inside_vs_rmdir" ~setup:folder
        ~ours:[B (write "d/new.txt" "ours"); B (Mkdir "d/sub")]
        ~theirs:[A (Rmdir "d")];
      conflict "k1_file_vs_folder" ~setup:[]
        ~ours:[B (write "x" "a file")]
        ~theirs:[A (Mkdir "x"); A (write "x/in.txt" "inside")];
      conflict "k1_folder_vs_file" ~setup:[]
        ~ours:[B (Mkdir "x"); B (write "x/in.txt" "inside")]
        ~theirs:[A (write "x" "a file")];
    ]
