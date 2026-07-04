(* IPC-response snapshots. Unlike the tree snapshots, these dump the actual JSON
   the daemon returns for the listing and change-feed actions, so the FileProvider
   contract (dir keys, logical size, content-hash etags, dirty state, and the
   changes_since / cursor delta with stale detection) is exercised directly. *)

open Test_runner

(* list_dir / list_all: keys, logical size, etag (content hash), dirty state. *)
let listing_scenarios : scenario list =
  [
    {
      name = "files: dirty then clean etag";
      steps =
        [
          Write { path = "a.txt"; content = "hello" };
          Write { path = "b.txt"; content = "world" };
        ];
    };
    {
      name = "nested directories keyed as full paths";
      steps =
        [
          Mkdir "sub";
          Drain;
          Write { path = "sub/c.txt"; content = "nested" };
          Write { path = "top.txt"; content = "top" };
        ];
    };
    {
      name = "identical content shares an etag";
      steps =
        [
          Write { path = "x.txt"; content = "same bytes" };
          Drain;
          Write { path = "y.txt"; content = "same bytes" };
        ];
    };
  ]

(* changes_since / cursor: working delta, up-to-date, and stale detection. *)
let changes_scenarios : scenario list =
  [
    {
      name = "foreign put";
      steps = [Write { path = "a.txt"; content = "hi" }; Drain];
    };
    {
      name = "foreign mkdir then put";
      steps =
        [
          Mkdir "sub";
          Drain;
          Write { path = "sub/f.txt"; content = "deep" };
          Drain;
        ];
    };
    {
      name = "foreign delete";
      steps =
        [Write { path = "a.txt"; content = "x" }; Drain; Delete "a.txt"; Drain];
    };
    {
      name = "foreign rename";
      steps =
        [
          Write { path = "a.txt"; content = "x" };
          Drain;
          Rename { src = "a.txt"; dst = "b.txt" };
          Drain;
        ];
    };
  ]

let () =
  print_endline "########## LISTING ##########";
  run_ipc listing_scenarios;
  print_endline "########## CHANGES ##########";
  run_ipc_changes changes_scenarios
