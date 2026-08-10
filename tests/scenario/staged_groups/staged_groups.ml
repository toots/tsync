(* Staging when a cache group holds more than one chunk.

   Everywhere else the two sizes are equal, so a group is a single chunk at
   offset zero and grouping never shows. Here the chunk is 8 bytes and the cache
   group 24 (TSYNC_CHUNK_SIZE and TSYNC_CACHE_CHUNK_SIZE, in dune), so three
   chunks share a group and the counts distinguish per-chunk staging from
   per-group staging.

   [ShowStaged] is the number to watch: manifests stay one per edited file while
   bodies say how the bytes underneath are divided. [ShowChunks] prints the
   slots, S staged, I inherited, Z a hole. *)

open Test_runner

(* Six chunks, two whole groups, one distinct run per chunk so a misplaced write
   shows up as content rather than as a count. *)
let body = "AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDDEEEEEEEEFFFFFFFF"

let scenarios : scenario list =
  [
    {
      name = "a write covering the file stages it";
      steps =
        [
          Write { path = "whole.txt"; content = body };
          ShowStaged;
          ShowChunks "whole.txt";
          Drain;
          ShowStaged;
          ShowChunks "whole.txt";
        ];
    };
    {
      name = "a partial write stages the group it lands in";
      steps =
        [
          Write { path = "part.txt"; content = body };
          Drain;
          (* Inside the first group: the other two members of that group have to
             come along, or the group's key would name bytes we no longer hold.
             The second group is untouched and stays inherited. *)
          WriteAt { path = "part.txt"; offset = 8; content = "bbbbbbbb" };
          ShowStaged;
          ShowChunks "part.txt";
          ReadRange { path = "part.txt"; offset = 0; len = 48 };
          Drain;
          ShowChunks "part.txt";
        ];
    };
    {
      name = "a second write to the same group adds nothing";
      steps =
        [
          Write { path = "twice.txt"; content = body };
          Drain;
          WriteAt { path = "twice.txt"; offset = 0; content = "aaaaaaaa" };
          ShowStaged;
          (* A different member of the group already staged. *)
          WriteAt { path = "twice.txt"; offset = 16; content = "cccccccc" };
          ShowStaged;
          ReadRange { path = "twice.txt"; offset = 0; len = 48 };
          Drain;
          ShowChunks "twice.txt";
        ];
    };
    {
      name = "a grow extends the last chunk and then adds one";
      steps =
        [
          Write { path = "grow.txt"; content = "AAAAAAAABBBB" };
          Drain;
          (* Into the tail of the last chunk: no new chunk, no fetch. *)
          WriteAt { path = "grow.txt"; offset = 12; content = "bbbb" };
          ShowStaged;
          ShowChunks "grow.txt";
          (* Past it: a chunk appears in the same group. *)
          WriteAt { path = "grow.txt"; offset = 16; content = "CCCCCCCC" };
          ShowStaged;
          ShowChunks "grow.txt";
          ReadRange { path = "grow.txt"; offset = 0; len = 24 };
          Drain;
          ShowChunks "grow.txt";
        ];
    };
    {
      name = "a truncate drops chunks from a group";
      steps =
        [
          Write { path = "cut.txt"; content = body };
          Drain;
          (* Back into the middle of the first group, so the second group goes
             entirely and the first keeps one member. *)
          Truncate { path = "cut.txt"; size = 12 };
          ShowStaged;
          ShowChunks "cut.txt";
          ReadRange { path = "cut.txt"; offset = 0; len = 12 };
          Drain;
          ShowChunks "cut.txt";
          ShowChunkCache;
        ];
    };
  ]

let () = Test_runner.run scenarios
