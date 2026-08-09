(* Expire scenarios: [expire] drops trashed folders, versions and journal entries
   older than a cutoff. "all" expires every existing version (cutoff = now);
   "none" expires nothing (cutoff = epoch).

   The chunks this orphans stay on the backend — visible in each snapshot below as
   a chunk no file references. Reclaiming them is a separate step with separate
   requirements; see ../gc/gc.ml. See ../base/base.ml for the single-client
   harness. *)

open Test_runner

let scenarios : scenario list =
  [
    {
      name = "expire all: old version dropped, its chunk left behind";
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
      name = "expire all: deleted file dropped, chunk left behind";
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
      (* A trashed folder past the cutoff loses the subtree kept for undo, which
         is what stops its chunk being referenced. *)
      name = "expire all: trashed folder dropped, chunk left behind";
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
      (* Emptying the folder leaves its namespace behind on a store that has
         real directories, so the trashed subtree lists as the bare directory
         key: no child of it, and no manifest to fetch. *)
      name = "expire all: trashed folder emptied first";
      steps =
        [
          Mkdir "d";
          Drain;
          Write { path = "d/a.txt"; content = "gone before the folder" };
          Drain;
          Delete "d/a.txt";
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
