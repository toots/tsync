(* Base scenarios: one representative case per file operation. To add another
   suite, create a sibling directory with its own scenario file, [.expected]
   snapshot, and the same three dune stanzas (see tests/base/dune). *)

open Test_runner

let scenarios : scenario list =
  [
    {
      name = "create";
      steps = [Write { path = "a.txt"; content = "hello tsync" }; Drain];
    };
    {
      name = "copy";
      steps =
        [
          Write { path = "a.txt"; content = "same content" };
          Drain;
          Write { path = "b.txt"; content = "same content" };
          Drain;
        ];
    };
    {
      name = "rename";
      steps =
        [
          Write { path = "a.txt"; content = "renamed content" };
          Drain;
          Rename { src = "a.txt"; dst = "b.txt" };
          Drain;
        ];
    };
    {
      name = "delete";
      steps =
        [
          Write { path = "a.txt"; content = "doomed" };
          Drain;
          Delete "a.txt";
          Drain;
        ];
    };
    {
      name = "evict";
      steps =
        [Write { path = "a.txt"; content = "evicted" }; Drain; Evict "a.txt"];
    };
    {
      name = "restore";
      steps =
        [
          Write { path = "a.txt"; content = "round trip" };
          Drain;
          Evict "a.txt";
          Restore "a.txt";
        ];
    };
    {
      name = "mkdir";
      steps =
        [
          Mkdir "sub";
          Drain;
          Write { path = "sub/a.txt"; content = "nested" };
          Drain;
        ];
    };
    { name = "rmdir"; steps = [Mkdir "sub"; Drain; Rmdir "sub"; Drain] };
    {
      (* Renaming a non-empty folder is O(1): the file's backend key is under the
         folder's stable id, so it doesn't move — only the folder marker does. *)
      name = "rename_dir";
      steps =
        [
          Mkdir "d";
          Drain;
          Write { path = "d/a.txt"; content = "in folder" };
          Drain;
          Rename { src = "d"; dst = "d2" };
          Drain;
        ];
    };
    {
      (* Deleting a non-empty folder moves its marker to trash; the subtree stays
         on the backend (for undo / expire), and the local copy is dropped. *)
      name = "rmdir_nonempty";
      steps =
        [
          Mkdir "d";
          Drain;
          Write { path = "d/a.txt"; content = "trash me" };
          Drain;
          Rmdir "d";
          Drain;
        ];
    };
    {
      name = "symlink";
      steps =
        [
          Write { path = "real.txt"; content = "target data" };
          Drain;
          Symlink { path = "link.txt"; target = "real.txt" };
          Drain;
        ];
    };
    {
      name = "symlink delete";
      steps =
        [
          Symlink { path = "link.txt"; target = "gone.txt" };
          Drain;
          Delete "link.txt";
          Drain;
        ];
    };
  ]

let () = run scenarios

(* Live symlink creation is only allowed under the [`Keep] policy (the default
   above); [`Follow]/[`Skip] domains must never contain symlink objects. *)
let rejection_scenario name : scenario =
  { name; steps = [Symlink { path = "link.txt"; target = "real.txt" }] }

let () =
  run ~symlink_policy:`Follow
    [rejection_scenario "follow: symlink creation rejected"]

let () =
  run ~symlink_policy:`Skip
    [rejection_scenario "skip: symlink creation rejected"]
