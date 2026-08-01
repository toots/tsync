(* Behavioral snapshot of serving one range of a file rather than the whole one.

   This is the seam behind NSFileProviderPartialContentFetching: the macOS File
   Provider asks for the range an application actually read, gets a file holding
   just that range at just that offset, and stitches the pieces together itself.
   So the two things worth recording are where the bytes land — a range written
   at the wrong offset is silent corruption, and the file's own length is what
   shows it, since everything before the range is a hole — and how much of the
   file is local afterwards, which is the whole point of not materializing it.

   The chunk size is forced to 8 bytes (TSYNC_CHUNK_SIZE, set in dune) so a small
   fixture spans several chunks. Content is laid out one distinct run per chunk:
     chunk#0 = "01234567"  chunk#1 = "89ABCDEF"  chunk#2 = "ghijklmn" *)

open Test_runner

let big = "0123456789ABCDEFghijklmn"

let scenarios : scenario list =
  [
    {
      name = "a range is served without materializing the file";
      steps =
        [
          Write { path = "big.txt"; content = big };
          Drain;
          Evict "big.txt";
          ShowChunks "big.txt";
          (* The middle chunk alone: the file that comes back is 16 bytes long,
             the first 8 of them a hole. *)
          FetchRange { path = "big.txt"; offset = 8; len = 8 };
          ShowChunks "big.txt";
        ];
    };
    {
      name = "ranges covering the file reassemble it";
      steps =
        [
          Write { path = "cover.txt"; content = big };
          Drain;
          Evict "cover.txt";
          FetchRange { path = "cover.txt"; offset = 0; len = 8 };
          FetchRange { path = "cover.txt"; offset = 8; len = 8 };
          FetchRange { path = "cover.txt"; offset = 16; len = 8 };
          ShowChunks "cover.txt";
        ];
    };
    {
      name = "a range straddling the end is served short, not padded";
      steps =
        [
          Write { path = "tail.txt"; content = big };
          Drain;
          Evict "tail.txt";
          (* Asked for 16 bytes with 8 left: the short answer is what tells the
             caller where the file stops. *)
          FetchRange { path = "tail.txt"; offset = 16; len = 16 };
          (* Wholly past the end: nothing served, but a file all the same — the
             caller is handed this path either way. *)
          FetchRange { path = "tail.txt"; offset = 64; len = 8 };
          ShowChunks "tail.txt";
        ];
    };
    {
      name = "a range spanning several chunks fetches each of them";
      steps =
        [
          Write { path = "span.txt"; content = big };
          Drain;
          Evict "span.txt";
          FetchRange { path = "span.txt"; offset = 4; len = 12 };
          ShowChunks "span.txt";
        ];
    };
    {
      name = "unsynced edits are visible to a range read";
      steps =
        [
          Write { path = "edit.txt"; content = big };
          Drain;
          Evict "edit.txt";
          WriteAt { path = "edit.txt"; offset = 8; content = "XXXXXXXX" };
          (* Staged, not published: the range must show the edit rather than
             what the backend still holds. *)
          FetchRange { path = "edit.txt"; offset = 8; len = 8 };
          ShowChunks "edit.txt";
        ];
    };
    {
      name = "a hole from a grow reads as zeros";
      steps =
        [
          Write { path = "grow.txt"; content = "01234567" };
          Drain;
          Truncate { path = "grow.txt"; size = 24 };
          FetchRange { path = "grow.txt"; offset = 8; len = 16 };
          ShowChunks "grow.txt";
        ];
    };
  ]

let () = run scenarios
