(* Behavioral snapshot of the cache-size cap (maxCache). Chunk size and cap are
   both forced to 8 bytes (see dune), so each single-chunk fixture is one slot.
   The cap needs no bookkeeping — every body is interchangeable and re-fetchable
   — so a sweep drops the coldest and a read that misses fetches again. Staged
   bodies live outside the store and are never touched. *)

open Test_runner

(* The trailing [Drain] spaces successive reads out in time, so coldest-first
   ordering is deterministic. *)
let cache path = [ReadRange { path; offset = 0; len = 8; stream = None }; Drain]

let scenarios : scenario list =
  [
    {
      name = "the sweep drops the coldest bodies; a re-read fetches them back";
      steps =
        [
          Write { path = "a.txt"; content = "aaaaaaaa" };
          Drain;
          Write { path = "b.txt"; content = "bbbbbbbb" };
          Drain;
          Write { path = "c.txt"; content = "cccccccc" };
          Drain;
          Evict "a.txt";
          Evict "b.txt";
          Evict "c.txt";
        ]
        (* Read a, then b, then c — a is the coldest. *)
        @ cache "a.txt"
        @ cache "b.txt" @ cache "c.txt"
        @ [
            ShowChunkCache;
            EnforceCache;
            ShowChunkCache;
            ShowChunks "a.txt";
            ShowChunks "b.txt";
            ShowChunks "c.txt";
            (* Dropped bodies are not lost data: reading returns the same bytes. *)
            ReadRange { path = "a.txt"; offset = 0; len = 8; stream = None };
            ShowChunks "a.txt";
          ];
    };
    {
      name = "a staged file's bodies are never dropped";
      steps =
        [Write { path = "x.txt"; content = "xxxxxxxx" }; Drain; Evict "x.txt"]
        @ cache "x.txt"
        @ [
            (* Unsynced edits: the only copy of these bytes, and outside the
               store the cap sweeps. *)
            StageWrite { path = "z.txt"; content = "zzzzzzzz" };
            EnforceCache;
            ShowChunks "x.txt";
            ShowChunks "z.txt";
            ReadRange { path = "z.txt"; offset = 0; len = 8; stream = None };
          ];
    };
  ]

let () = run scenarios
