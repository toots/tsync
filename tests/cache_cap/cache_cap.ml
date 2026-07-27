(* Behavioral snapshot of the cache-size cap (maxCache). Chunk size and the cap
   are both forced to 8 bytes (see dune), so each single-chunk fixture is exactly
   one "slot": the cap holds one chunk body. The cap needs no bookkeeping — every
   body is interchangeable and re-fetchable — so a sweep just drops the coldest
   bodies, and a read that finds one missing fetches it again. Staged bodies live
   outside the store and are never touched. *)

open Test_runner

(* Pull a file's one chunk into the store. The trailing [Drain] spaces successive
   reads out in time so the coldest-first order is deterministic. *)
let cache path = [ReadRange { path; offset = 0; len = 8 }; Drain]

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
            ReadRange { path = "a.txt"; offset = 0; len = 8 };
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
            ReadRange { path = "z.txt"; offset = 0; len = 8 };
          ];
    };
  ]

let () = run scenarios
