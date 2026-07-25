(* Behavioral snapshot of the cache-size cap (maxCache). Chunk size and the cap
   are both forced to 8 bytes (see dune), so each single-chunk fixture is exactly
   one "slot": the cap holds one file. Files are uploaded (import leaves no local
   data), then demand-paged into the cache by reading them; a cap sweep then
   evicts the coldest clean files until usage is back under the cap, never
   touching a file with unsynced (dirty) data. *)

open Test_runner

(* Cache a file by reading its one chunk, then close it (leaving the data
   resident with a fresh access time). The trailing [Drain] spaces successive
   opens out in time so the least-recently-used order is deterministic. *)
let cache path =
  [OpenRead path; ReadRange { path; offset = 0; len = 8 }; Release path; Drain]

let scenarios : scenario list =
  [
    {
      name = "coldest clean files evicted down to the cap; hottest kept";
      steps =
        [
          Write { path = "a.txt"; content = "aaaaaaaa" };
          Drain;
          Write { path = "b.txt"; content = "bbbbbbbb" };
          Drain;
          Write { path = "c.txt"; content = "cccccccc" };
          Drain;
        ]
        (* Read a, then b, then c — c is the most recently used. *)
        @ cache "a.txt"
        @ cache "b.txt" @ cache "c.txt"
        @ [
            ShowResidency "a.txt";
            ShowResidency "b.txt";
            ShowResidency "c.txt";
            EnforceCache;
            ShowResidency "a.txt";
            ShowResidency "b.txt";
            ShowResidency "c.txt";
          ];
    };
    {
      name = "clean files evicted to the cap; a dirty (unsynced) file is kept";
      steps =
        [
          Write { path = "x.txt"; content = "xxxxxxxx" };
          Drain;
          Write { path = "y.txt"; content = "yyyyyyyy" };
          Drain;
        ]
        @ cache "x.txt" @ cache "y.txt"
        @ [
            (* Local edit not yet uploaded: its data is never dropped, so it is
               neither counted toward the cap nor evicted. *)
            DirtyWrite { path = "z.txt"; content = "zzzzzzzz" };
            EnforceCache;
            ShowResidency "x.txt";
            ShowResidency "y.txt";
            ShowResidency "z.txt";
          ];
    };
  ]

let () = run scenarios
