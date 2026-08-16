(* Staging when a cache group holds more than one chunk: 8-byte chunks in a
   24-byte group (TSYNC_CHUNK_SIZE and TSYNC_CACHE_CHUNK_SIZE, in dune), where
   every other runner test leaves the two equal and grouping never shows.

   [ShowStaged]'s body count is what to watch, since it says how the bytes
   under one edited file are divided; [ShowChunks] prints the slots, S staged,
   I inherited, Z a hole. *)

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
      (* The shape rclone writes in: a chunk arrives in pieces, so the first
         piece lands in a member the group has not staged yet and covers only
         part of it. *)
      name = "a partial write into a member the group has not staged";
      steps =
        [
          (* Held rather than drained: the first chunk stays staged rather than
             becoming inherited, so the group is one this file already owns a
             body for and the second chunk is a hole inside it. *)
          Uploads `Paused;
          Write { path = "piece.txt"; content = "AAAAAAAA" };
          ShowChunks "piece.txt";
          (* Into the second chunk, but not all of it. *)
          WriteAt { path = "piece.txt"; offset = 8; content = "bb" };
          ShowStaged;
          ShowChunks "piece.txt";
          (* And the third, still partly. *)
          WriteAt { path = "piece.txt"; offset = 18; content = "cc" };
          ShowChunks "piece.txt";
          ReadRange { path = "piece.txt"; offset = 0; len = 24 };
          Uploads `Running;
          Drain;
          ShowChunks "piece.txt";
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
