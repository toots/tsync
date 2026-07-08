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
