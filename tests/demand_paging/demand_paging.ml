(* Behavioral snapshot of demand paging: an evicted file is faulted back in as a
   sparse file whose chunks are fetched only as reads touch them; the per-chunk
   residency is durable (survives close/reopen); and editing one chunk re-uploads
   only that chunk, leaving the others to be fetched from the backend on read.

   The chunk size is forced to 8 bytes (TSYNC_CHUNK_SIZE, set in dune) so a small
   fixture spans several chunks. Content is laid out one distinct run per chunk:
     chunk#0 = "01234567"  chunk#1 = "89ABCDEF"  chunk#2 = "ghijklmn" *)

open Test_runner

let big = "0123456789ABCDEFghijklmn"
let edit = "aaaaaaaabbbbbbbbcccccccc"

let scenarios : scenario list =
  [
    {
      name = "reads fetch only touched chunks; residency is durable";
      steps =
        [
          Write { path = "big.txt"; content = big };
          Drain;
          Evict "big.txt";
          OpenRead "big.txt";
          ShowResidency "big.txt";
          ReadRange { path = "big.txt"; offset = 0; len = 8 };
          ShowResidency "big.txt";
          ReadRange { path = "big.txt"; offset = 16; len = 8 };
          ShowResidency "big.txt";
          (* Drop the in-memory view; the sidecar residency must persist. *)
          Release "big.txt";
          ShowResidency "big.txt";
          (* Reopen resumes from the sidecar — the two chunks stay present. *)
          OpenRead "big.txt";
          ShowResidency "big.txt";
          (* Reading the last hole completes the file: it collapses to fully
             cached. *)
          ReadRange { path = "big.txt"; offset = 8; len = 8 };
          ShowResidency "big.txt";
        ];
    };
    {
      name = "editing one chunk re-uploads only that chunk";
      steps =
        [
          Write { path = "edit.txt"; content = edit };
          Drain;
          Evict "edit.txt";
          OpenRead "edit.txt";
          (* Overwrite chunk#1 in full — no read-modify-write fetch needed. *)
          WriteAt { path = "edit.txt"; offset = 8; content = "BBBBBBBB" };
          ShowResidency "edit.txt";
          Release "edit.txt";
          Drain;
          (* Only chunk#1 was dirty, so only it is re-uploaded; chunks #0/#2 keep
             their prior entries and remain absent locally. *)
          ShowResidency "edit.txt";
          (* Reading pulls the untouched chunks from the backend and reassembles
             the edited content. *)
          ReadRange { path = "edit.txt"; offset = 0; len = 24 };
          ShowResidency "edit.txt";
        ];
    };
  ]

let () = run scenarios
