(* One representative case per file operation. A new suite is a sibling
   directory with its own scenario file and [.expected] snapshot; the dune rules
   that run it are generated (see tests/gen-dune.sh). *)

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
          (* Read first: a whole-file write leaves nothing in the chunk store, so
             the eviction would have nothing to drop and the snapshot could not
             tell a working evict from a no-op. *)
          ReadRange { path = "a.txt"; offset = 0; len = 7; stream = None };
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
      (* A full resync rebuilds the mirror and chunk store from the backend.
         Unsynced edits are the one thing it must not touch. *)
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
      (* Deleting a key drops its staged bodies too: nothing else references
         them and there is no longer anywhere to upload them to. *)
      name = "delete drops staged bodies";
      steps =
        [
          Write { path = "doomed.txt"; content = "published" };
          Drain;
          StageWrite { path = "doomed.txt"; content = "edited, not uploaded" };
          ShowStaged;
          Delete "doomed.txt";
          Drain;
          ShowStaged;
        ];
    };
    {
      (* A body no staged manifest names is unreachable, so the startup sweep
         frees it — while a body the live staged manifest names survives, and
         its upload still works. *)
      name = "startup reclaims orphaned staged bodies";
      steps =
        [
          Write { path = "kept.txt"; content = "published" };
          Drain;
          StageWrite { path = "kept.txt"; content = "edited, not uploaded" };
          OrphanStagedBody;
          ShowStaged;
          ReclaimStaged;
          ShowStaged;
          Drain;
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
      (* A query changes nothing: a miss must stay a miss, so [names] after each
         stat must be empty. Resolving a path must not mint a folder id and
         persist a marker, which would bring the directory back. *)
      name = "stat_absent_creates_nothing";
      steps =
        [
          Stat "no-such-file.txt";
          ShowNames "";
          Stat "no-such-dir/";
          ShowNames "";
          Mkdir "sub";
          Drain;
          Rmdir "sub";
          Drain;
          Stat "sub/";
          ShowNames "";
        ];
    };
    {
      (* O(1): the file's backend key hangs off the folder's stable id, so only
         the marker moves. *)
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
