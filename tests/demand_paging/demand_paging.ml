(* Behavioral snapshot of demand paging: an evicted file is read back chunk by
   chunk, and only the chunks a read touches are fetched. Nothing records which
   ones are local — the chunk store answers that by what it holds — so this is
   also the snapshot for "presence survives close/reopen": there is no state to
   survive.

   The chunk size is forced to 8 bytes (TSYNC_CHUNK_SIZE, set in dune) so a small
   fixture spans several chunks. Content is laid out one distinct run per chunk:
     chunk#0 = "01234567"  chunk#1 = "89ABCDEF"  chunk#2 = "ghijklmn" *)

open Test_runner

let big = "0123456789ABCDEFghijklmn"
let edit = "aaaaaaaabbbbbbbbcccccccc"

let scenarios : scenario list =
  [
    {
      name = "reads fetch only the chunks they touch";
      steps =
        [
          Write { path = "big.txt"; content = big };
          Drain;
          Evict "big.txt";
          ShowChunks "big.txt";
          ReadRange { path = "big.txt"; offset = 0; len = 8 };
          ShowChunks "big.txt";
          ReadRange { path = "big.txt"; offset = 16; len = 8 };
          ShowChunks "big.txt";
          (* Reading the remaining hole completes the file. *)
          ReadRange { path = "big.txt"; offset = 8; len = 8 };
          ShowChunks "big.txt";
        ];
    };
    {
      name = "a chunk deleted under a reader is fetched again";
      steps =
        [
          Write { path = "gone.txt"; content = big };
          Drain;
          ReadRange { path = "gone.txt"; offset = 0; len = 8 };
          DeleteCachedChunk { path = "gone.txt"; index = 0 };
          ShowChunks "gone.txt";
          (* The cap may unlink a body at any time, so a miss is ordinary: the
             read refetches and still returns the right bytes. *)
          ReadRange { path = "gone.txt"; offset = 0; len = 8 };
          ShowChunks "gone.txt";
        ];
    };
    {
      name = "editing one chunk re-uploads only that chunk";
      steps =
        [
          Write { path = "edit.txt"; content = edit };
          Drain;
          Evict "edit.txt";
          (* Overwrite chunk#1 in full — no read-modify-write fetch needed. *)
          WriteAt { path = "edit.txt"; offset = 8; content = "BBBBBBBB" };
          ShowChunks "edit.txt";
          Close "edit.txt";
          Drain;
          (* Chunks #0/#2 were inherited unchanged and are still not local. *)
          ShowChunks "edit.txt";
          ReadRange { path = "edit.txt"; offset = 0; len = 24 };
          ShowChunks "edit.txt";
        ];
    };
    {
      name = "a write covering part of a chunk fetches just that chunk";
      steps =
        [
          Write { path = "rmw.txt"; content = edit };
          Drain;
          Evict "rmw.txt";
          (* Two bytes inside chunk#1: its other bytes must survive, so exactly
             that chunk is fetched and copied into a staged body. *)
          WriteAt { path = "rmw.txt"; offset = 10; content = "XX" };
          ShowChunks "rmw.txt";
          Close "rmw.txt";
          Drain;
          ReadRange { path = "rmw.txt"; offset = 8; len = 8 };
        ];
    };
    {
      name = "shrinking into a chunk that is not local fetches just that chunk";
      steps =
        [
          Write { path = "shrink.txt"; content = big };
          Drain;
          Evict "shrink.txt";
          (* The new end lands inside chunk#0, whose bytes must survive the
             resize: exactly that one chunk is fetched. *)
          Truncate { path = "shrink.txt"; size = 4 };
          ShowChunks "shrink.txt";
          Close "shrink.txt";
          Drain;
          ReadRange { path = "shrink.txt"; offset = 0; len = 8 };
        ];
    };
    {
      name = "growing by truncate writes no bytes and reads as zeros";
      steps =
        [
          Write { path = "grow.txt"; content = "01234567" };
          Drain;
          Truncate { path = "grow.txt"; size = 24 };
          (* Z slots: holes, no body on disk and nothing fetched. *)
          ShowChunks "grow.txt";
          ReadRange { path = "grow.txt"; offset = 8; len = 8 };
          Close "grow.txt";
          Drain;
          ShowChunks "grow.txt";
          ReadRange { path = "grow.txt"; offset = 0; len = 24 };
        ];
    };
  ]

let () = run scenarios
