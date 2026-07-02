(* Versioning scenarios: every modify/rename/delete saves a timestamped copy of
   the manifest under .versions/, and [revert] restores one without downloading
   content (the restored file stays cached=false until opened). See
   ../base/base.ml for the single-client harness. *)

open Test_runner

let scenarios : scenario list =
  [
    {
      name = "modify keeps prior versions";
      steps =
        [
          Write { path = "foo.txt"; content = "one" };
          Drain;
          Write { path = "foo.txt"; content = "two two" };
          Drain;
          Write { path = "foo.txt"; content = "three three three" };
          Drain;
        ];
    };
    {
      name = "delete keeps a version";
      steps =
        [
          Write { path = "foo.txt"; content = "keep me" };
          Drain;
          Delete "foo.txt";
        ];
    };
    {
      name = "rename versions the old path";
      steps =
        [
          Write { path = "a.txt"; content = "content a" };
          Drain;
          Rename { src = "a.txt"; dst = "b.txt" };
        ];
    };
    {
      name = "revert a deleted file (dataless)";
      steps =
        [
          Write { path = "foo.txt"; content = "deleted content" };
          Drain;
          Delete "foo.txt";
          Drain;
          RevertVersion { path = "foo.txt"; version = None };
        ];
    };
    {
      name = "revert a modified file to its previous version";
      steps =
        [
          Write { path = "foo.txt"; content = "one" };
          Drain;
          Write { path = "foo.txt"; content = "two" };
          Drain;
          Write { path = "foo.txt"; content = "three" };
          Drain;
          RevertVersion { path = "foo.txt"; version = None };
        ];
    };
  ]

let () = run ~versioning:true scenarios
