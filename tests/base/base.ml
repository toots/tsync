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
        [
          Write { path = "a.txt"; content = "evicted" };
          Drain;
          (* Read it first: a whole-file write leaves nothing in the chunk store,
             so without this the eviction would have nothing to drop and the
             snapshot could not tell a working evict from a no-op. *)
          ReadRange { path = "a.txt"; offset = 0; len = 7 };
          ShowChunks "a.txt";
          Evict "a.txt";
          ShowChunks "a.txt";
        ];
    };
    {
      name = "restore";
      steps =
        [
          Write { path = "a.txt"; content = "round trip" };
          Drain;
          Evict "a.txt";
          ShowChunks "a.txt";
          Restore "a.txt";
          ShowChunks "a.txt";
        ];
    };
    {
      (* A full resync wipes the manifest mirror and the chunk store and rebuilds
         them from the backend. Unsynced edits are the one thing it must not
         touch: nothing else holds those bytes. *)
      name = "unsynced edits survive a full resync";
      steps =
        [
          Write { path = "kept.txt"; content = "published" };
          Drain;
          StageWrite { path = "kept.txt"; content = "edited, not uploaded" };
          (* A file with only staged edits has no sidecar yet, and readdir must
             still list it — it is the user's newest data. *)
          ShowNames "";
          ClearCache;
          ShowNames "";
          ShowChunks "kept.txt";
          RecoverStaged;
          Drain;
          ShowChunks "kept.txt";
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
          (* readdir must show the file and nothing else — no internal markers,
             no escaped on-disk spelling. *)
          ShowNames "sub";
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
