(* Expire scenarios: [expire] deletes versions older than a cutoff, then
   garbage-collects any chunk no longer referenced by a live file or a surviving
   version. "all" expires every existing version (cutoff = now); "none" expires
   nothing (cutoff = epoch). See ../base/base.ml for the single-client harness. *)

open Test_runner

let scenarios : scenario list =
  [
    {
      name = "expire all: old version's chunk collected, live chunk kept";
      steps =
        [
          Write { path = "foo.txt"; content = "one" };
          Drain;
          Write { path = "foo.txt"; content = "two two" };
          Drain;
          Expire "all";
        ];
    };
    {
      name = "expire all: deleted file fully reclaimed";
      steps =
        [
          Write { path = "foo.txt"; content = "gone soon" };
          Drain;
          Delete "foo.txt";
          Expire "all";
        ];
    };
    {
      name = "expire at a cutoff: older version dropped, newer kept";
      steps =
        [
          Write { path = "foo.txt"; content = "one" };
          Drain;
          Write { path = "foo.txt"; content = "two two" };
          (* saves version(one) *)
          Drain;
          Mark;
          (* cutoff falls here: version(one) is older, version(two) is newer *)
          Drain;
          Write { path = "foo.txt"; content = "three three three" };
          (* saves version(two two) *)
          Drain;
          Expire "mark";
        ];
    };
    {
      (* A trashed folder past the cutoff is reclaimed: its subtree (kept intact
         on delete for undo) is deleted and its now-unreferenced chunk collected. *)
      name = "expire all: trashed folder reclaimed";
      steps =
        [
          Mkdir "d";
          Drain;
          Write { path = "d/a.txt"; content = "trash me" };
          Drain;
          Rmdir "d";
          Drain;
          Expire "all";
        ];
    };
    {
      name = "expire none: nothing removed";
      steps =
        [
          Write { path = "foo.txt"; content = "one" };
          Drain;
          Write { path = "foo.txt"; content = "two two" };
          Drain;
          Expire "none";
        ];
    };
  ]

let () = run ~versioning:true scenarios
