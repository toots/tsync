(* Two full clients (A and B) share a backend but keep separate caches, data dirs
   and journal identities. A makes changes through the user-facing IPC
   operations; B picks them up via [Sync], the same path the background poller
   takes. The snapshot shows both views plus the shared backend state. *)

open Test_runner

let foreign_put =
  {
    name = "foreign_put";
    steps = [A (Write { path = "foo.txt"; content = "hello" }); A Drain; B Sync];
  }

let foreign_delete =
  {
    name = "foreign_delete";
    steps =
      [
        A (Write { path = "foo.txt"; content = "hello" });
        A Drain;
        B Sync;
        A (Delete "foo.txt");
        A Drain;
        B Sync;
      ];
  }

(* A overwrites a file B has cached: B's stale cache is evicted and the next
   read downloads A's version. *)
let foreign_overwrite =
  {
    name = "foreign_overwrite";
    steps =
      [
        A (Write { path = "foo.txt"; content = "hello" });
        A Drain;
        B Sync;
        B (Restore "foo.txt");
        A (Write { path = "foo.txt"; content = "hello, world!" });
        A Drain;
        B Sync;
      ];
  }

(* Plain foreign rename, no concurrent activity: B's cached data and manifest
   move along with it. *)
let foreign_rename =
  {
    name = "foreign_rename";
    steps =
      [
        A (Write { path = "foo.txt"; content = "renamed content" });
        A Drain;
        B Sync;
        B (Restore "foo.txt");
        A (Rename { src = "foo.txt"; dst = "bar.txt" });
        A Drain;
        B Sync;
      ];
  }

(* Two renames land between B's syncs; one sync pass applies both journal
   entries in order (foo -> bar -> baz). *)
let foreign_rename_chain =
  {
    name = "foreign_rename_chain";
    steps =
      [
        A (Write { path = "foo.txt"; content = "chained" });
        A Drain;
        B Sync;
        A (Rename { src = "foo.txt"; dst = "bar.txt" });
        A Drain;
        A (Rename { src = "bar.txt"; dst = "baz.txt" });
        A Drain;
        B Sync;
      ];
  }

let foreign_mkdir =
  {
    name = "foreign_mkdir";
    steps =
      [
        A (Mkdir "sub");
        A Drain;
        A (Write { path = "sub/a.txt"; content = "nested" });
        A Drain;
        B Sync;
      ];
  }

let foreign_rmdir =
  {
    name = "foreign_rmdir";
    steps =
      [
        A (Mkdir "sub");
        A Drain;
        A (Write { path = "sub/a.txt"; content = "nested" });
        A Drain;
        B Sync;
        A (Delete "sub/a.txt");
        A Drain;
        A (Rmdir "sub");
        A Drain;
        B Sync;
      ];
  }

(* The shape a media manager produces: it re-creates a directory it already has
   before filling it, so one path is mkdir'd several times before anything
   deletes it. The marker's key derives from the parent's id and the name, so
   every mkdir addresses the same object and the final rmdir takes it away — one
   leftover marker brings the folder back on the next full resync. *)
let foreign_rmdir_after_repeated_mkdir =
  {
    name = "foreign_rmdir_after_repeated_mkdir";
    steps =
      [
        A (Mkdir "sub");
        A Drain;
        A (Write { path = "sub/a.txt"; content = "nested" });
        A Drain;
        A (Mkdir "sub");
        A Drain;
        A (Mkdir "sub");
        A Drain;
        B Sync;
        A (Delete "sub/a.txt");
        A Drain;
        A (Rmdir "sub");
        A Drain;
        B Sync;
      ];
  }

(* Both clients create one directory before either has seen the other, then each
   writes into it. The directory's id is a claim, and only one client can hold
   it: whoever loses has to adopt the winner's rather than keep its own, or its
   file ends up in a namespace nothing points at -- present on the backend,
   reachable from neither mount, reported by nothing.

   The rmdir case below misses this: with no file written, both markers land on
   the same key and the loser's namespace is empty, so nothing is stranded to
   find. *)
let concurrent_mkdir_then_write =
  {
    name = "concurrent_mkdir_then_write";
    steps =
      [
        A (Mkdir "sub");
        B (Mkdir "sub");
        A (Write { path = "sub/from-a.txt"; content = "a" });
        B (Write { path = "sub/from-b.txt"; content = "b" });
        A Drain;
        B Drain;
        A Sync;
        B Sync;
        A Drain;
        B Drain;
      ];
  }

(* Both clients create the same directory before either deletes it. Each mints a
   folder id locally when it has no marker, so this is where two markers for one
   path could come from, and rmdir removes only one. *)
let concurrent_mkdir_then_rmdir =
  {
    name = "concurrent_mkdir_then_rmdir";
    steps =
      [
        A (Mkdir "sub");
        A Drain;
        B (Mkdir "sub");
        B Drain;
        A Sync;
        B Sync;
        A (Rmdir "sub");
        A Drain;
        B Sync;
      ];
  }

(* Both clients create the same file with different content. B uploads last so
   the backend holds B's version; when A syncs, its clean local copy is
   evicted and converges on B's version (last writer wins). *)
let concurrent_create =
  {
    name = "concurrent_create";
    steps =
      [
        A (Write { path = "foo.txt"; content = "from A" });
        A Drain;
        B (Write { path = "foo.txt"; content = "from client B" });
        B Drain;
        A Sync;
      ];
  }

(* A overwrites a file B has open. The sync must not touch it: B keeps its cached
   version until the file is closed, and picks the change up on a later foreign op
   or a full resync. *)
let open_file_guard =
  {
    name = "open_file_guard";
    steps =
      [
        B (Write { path = "foo.txt"; content = "old content" });
        B Drain;
        A (Write { path = "foo.txt"; content = "NEW CONTENT, MUCH LONGER" });
        A Drain;
        B Sync;
        B (Close "foo.txt");
      ];
  }

(* Same situation, but B closes the file before syncing. B created the file
   but has no un-uploaded changes, so the foreign overwrite applies and B
   converges on A's version. *)
let open_file_guard_closed =
  {
    name = "open_file_guard_closed";
    steps =
      [
        B (Write { path = "foo.txt"; content = "old content" });
        B Drain;
        A (Write { path = "foo.txt"; content = "NEW CONTENT, MUCH LONGER" });
        A Drain;
        B (Close "foo.txt");
        B Sync;
      ];
  }

(* A deletes foo while B concurrently renames it. The backend rename fails
   (foo is already gone there), so B publishes its copy under a conflict-marked
   name: the file survives as "baz (conflicted copy from Client B).txt". *)
let delete_rename_race =
  {
    name = "delete_rename_race";
    steps =
      [
        A (Write { path = "foo.txt"; content = "saved by rename" });
        A Drain;
        B Sync;
        A (Delete "foo.txt");
        A Drain;
        B (Rename { src = "foo.txt"; dst = "baz.txt" });
        B Sync;
        (* A picks up B's published baz; both clients converge. *)
        A Sync;
      ];
  }

(* Both clients rename the same file. A's rename wins the backend race; B's
   backend rename fails (foo is gone there), so B publishes its copy under a
   conflict-marked name. B then syncs A's rename and adopts bar: the file ends
   up as bar.txt plus "baz (conflicted copy from Client B).txt". *)
let rename_rename_race =
  {
    name = "rename_rename_race";
    steps =
      [
        A (Write { path = "foo.txt"; content = "conflict content" });
        A Drain;
        B Sync;
        A (Rename { src = "foo.txt"; dst = "bar.txt" });
        A Drain;
        B (Rename { src = "foo.txt"; dst = "baz.txt" });
        B Sync;
        (* A picks up B's published baz; both clients converge. *)
        A Sync;
      ];
  }

(* The window itself: A's bytes are on the backend and the record says so, but
   no entry names them, so B sees nothing. Before the WAL there was no record to
   show here — the change was simply lost. *)
let crash_leaves_a_record =
  {
    name = "crash_leaves_a_record";
    steps =
      [
        A
          (StageWrite { path = "foo.txt"; content = "written but not announced" });
        A (CrashBeforeCommit "foo.txt");
        B Sync;
      ];
  }

(* The lost write. A's bytes reach the backend but the process dies before the
   journal entry is published: A looks synced locally and B can see nothing.
   Reconcile — which the daemon now runs at startup — publishes the entry under
   the key the record already holds, and B's next sync picks the file up. *)
let crash_before_commit =
  {
    name = "crash_before_commit";
    steps =
      [
        A
          (StageWrite { path = "foo.txt"; content = "written but not announced" });
        A (CrashBeforeCommit "foo.txt");
        (* B sees nothing: the bytes are there, no entry names them. *)
        B Sync;
        (* Restart. *)
        A RecoverStaged;
        A Drain;
        B Sync;
      ];
  }

(* Reconcile must not publish an entry for data that is gone: the record is the
   one a cancelled or superseded upload leaves behind, and its staged content
   was dropped. Telling peers to fetch it would strand them on a missing key. *)
let stale_record_discarded =
  {
    name = "stale_record_discarded";
    steps =
      [
        A (Write { path = "kept.txt"; content = "kept" });
        A Drain;
        A StaleRecord;
        A RecoverStaged;
        A Drain;
        B Sync;
      ];
  }

(* B holds the folder's files but not its id — what a client is left with when
   the mkdir predates the cursor it replays from. The next foreign put into that
   folder is what repairs it: the id comes from the marker the store already
   holds, so B ends up naming the folder the same way A does. *)
let foreign_put_readopts_a_forgotten_folder_id =
  {
    name = "foreign_put_readopts_a_forgotten_folder_id";
    steps =
      [
        A (Mkdir "sub");
        A Drain;
        A (Write { path = "sub/first.txt"; content = "one" });
        A Drain;
        B Sync;
        B (ForgetFolderId "sub");
        A (Write { path = "sub/second.txt"; content = "two" });
        A Drain;
        B Sync;
      ];
  }

let () =
  run_two_client_scenarios
    [
      foreign_put;
      foreign_delete;
      foreign_overwrite;
      foreign_rename;
      foreign_rename_chain;
      foreign_mkdir;
      foreign_rmdir;
      foreign_rmdir_after_repeated_mkdir;
      concurrent_mkdir_then_write;
      concurrent_mkdir_then_rmdir;
      concurrent_create;
      open_file_guard;
      open_file_guard_closed;
      delete_rename_race;
      rename_rename_race;
      crash_leaves_a_record;
      crash_before_commit;
      stale_record_discarded;
      foreign_put_readopts_a_forgotten_folder_id;
    ]
