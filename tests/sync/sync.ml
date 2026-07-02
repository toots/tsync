(* Sync scenarios: two full client instances (A and B) share the same backend
   but keep separate caches, data dirs and journal identities. Client A makes
   changes through the normal user-facing IPC operations; client B picks them
   up via [Sync] (the same code path as the background sync poller). The final
   snapshot shows both clients' views plus the shared backend state. *)

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

(* A overwrites a file B currently has open. The sync must not touch it: B
   keeps its cached version until the file is closed. (The change is only
   picked up again on a later foreign op or a full resync.) *)
let open_file_guard =
  {
    name = "open_file_guard";
    steps =
      [
        B (Write { path = "foo.txt"; content = "old content" });
        B Drain;
        B (Open "foo.txt");
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
        B (Open "foo.txt");
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
      concurrent_create;
      open_file_guard;
      open_file_guard_closed;
      delete_rename_race;
      rename_rename_race;
    ]
