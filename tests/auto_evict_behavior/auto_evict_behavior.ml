(* Behavioral snapshot of per-domain auto-evict: with the marker on, a file is
   evicted (cached=false) as its upload completes — no explicit Evict needed;
   with it off, the file stays resident (cached=true). Toggling mid-scenario
   evicts only the files uploaded while it was on. *)

open Test_runner

let scenarios : scenario list =
  [
    {
      name = "auto-evict on: evicted as upload completes";
      steps =
        [AutoEvict true; Write { path = "a.txt"; content = "hello" }; Drain];
    };
    {
      name = "auto-evict off: stays resident";
      steps =
        [AutoEvict false; Write { path = "b.txt"; content = "hello" }; Drain];
    };
    {
      name = "toggle off mid-scenario: only earlier files evicted";
      steps =
        [
          AutoEvict true;
          Write { path = "x.txt"; content = "one" };
          Drain;
          AutoEvict false;
          Write { path = "y.txt"; content = "two" };
          Drain;
        ];
    };
  ]

let () = run scenarios
