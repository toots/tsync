(* The daemon-level cases: a real socket, a real backend, and damage written
   through the store's own [put].

   [scramble-remote-chunk] is same-length damage, which is what a size
   comparison cannot see. *)

open Test_runner

let () =
  run
    [
      {
        name = "a good upload is accused of nothing";
        steps =
          [
            Write { path = "a.txt"; content = "hello tsync" };
            Drain;
            ListCorrupted;
          ];
      };
      {
        (* The marker is written by the store as it takes the bad bytes; nothing
           in the test asks for it. *)
        name = "a scrambled chunk is filed under its own key";
        steps =
          [
            Write { path = "a.txt"; content = "hello tsync" };
            Drain;
            ScrambleRemoteChunk { path = "a.txt"; index = 0 };
            RescanCorrupted;
            ListCorrupted;
          ];
      };
      {
        (* The loop closing. Writing the same bytes again would normally dedup —
           the chunk is in the session's memo and the store still holds the key,
           at the right size — so without the marker being consulted first, the
           scrambled body would survive and the marker would stand forever. *)
        name = "re-uploading the same bytes repairs it";
        steps =
          [
            Write { path = "a.txt"; content = "hello tsync" };
            Drain;
            ScrambleRemoteChunk { path = "a.txt"; index = 0 };
            RescanCorrupted;
            ListCorrupted;
            Write { path = "b.txt"; content = "hello tsync" };
            Drain;
            ListCorrupted;
          ];
      };
      {
        (* A copy is a store in its own right and checks what it is given. *)
        name = "damage on the secondary is reported against it";
        steps =
          [
            Write { path = "a.txt"; content = "hello tsync" };
            Drain;
            OnSecondary (ScrambleRemoteChunk { path = "a.txt"; index = 0 });
            RescanCorrupted;
            ListCorrupted;
          ];
      };
      {
        (* The primary still holds the bytes, so the copy is put right from it.
           The write goes to the damaged store alone: repairing one copy must not
           re-send the chunk to the healthy ones. *)
        name = "repair rewrites a bad copy from a good one";
        steps =
          [
            Write { path = "a.txt"; content = "hello tsync" };
            Drain;
            OnSecondary (ScrambleRemoteChunk { path = "a.txt"; index = 0 });
            RescanCorrupted;
            ListCorrupted;
            Repair;
            RescanCorrupted;
            ListCorrupted;
          ];
      };
      {
        (* Both copies gone means the bytes are gone: say so and name the key,
           rather than reporting a repair that did not happen. *)
        name = "nothing to repair from is reported, not silently skipped";
        steps =
          [
            Write { path = "a.txt"; content = "hello tsync" };
            Drain;
            ScrambleRemoteChunk { path = "a.txt"; index = 0 };
            OnSecondary (ScrambleRemoteChunk { path = "a.txt"; index = 0 });
            RescanCorrupted;
            Repair;
            RescanCorrupted;
            ListCorrupted;
          ];
      };
      {
        (* A whole-store check is the store's own work, so a store with nothing
           on its side to do it says so — and the command fails rather than
           reporting a check that never ran. A local store is swept by
           [gc --verify] instead. *)
        name = "a local store cannot be asked to check itself";
        steps =
          [
            Write { path = "a.txt"; content = "hello tsync" };
            Drain;
            RequestVerify;
          ];
      };
      {
        (* The sweep rides the collection that already walks every live chunk,
           so damage done behind the daemon's back is found without a second
           pass over the store. *)
        name = "gc --verify finds damage nothing wrote through the store";
        steps =
          [
            Write { path = "a.txt"; content = "hello tsync" };
            Drain;
            ScrambleBackendFile { path = "a.txt"; index = 0 };
            RescanCorrupted;
            ListCorrupted;
            GcVerify;
            RescanCorrupted;
            ListCorrupted;
          ];
      };
      {
        (* The chunk is referenced, so collecting it would take the file's only
           copy. It is kept where it belongs and filed — the manifest still
           names it, and repair is what has bytes to fix it with. *)
        name = "a chunk that fails the check is kept, not reclaimed";
        steps =
          [
            Write { path = "a.txt"; content = "hello tsync" };
            Drain;
            ScrambleBackendFile { path = "a.txt"; index = 0 };
            GcVerify;
            RescanCorrupted;
            ListCorrupted;
            ShowChunks "a.txt";
          ];
      };
      {
        (* An ordinary collection reads nothing, so it neither finds damage nor
           claims to have looked. *)
        name = "a plain collection checks nothing";
        steps =
          [
            Write { path = "a.txt"; content = "hello tsync" };
            Drain;
            ScrambleBackendFile { path = "a.txt"; index = 0 };
            Gc;
            RescanCorrupted;
            ListCorrupted;
          ];
      };
      {
        (* A marker names a chunk. Collect the chunk and the marker goes too,
           or it stands as a finding no repair can ever answer. *)
        name = "collecting a chunk takes its marker with it";
        steps =
          [
            Write { path = "a.txt"; content = "hello tsync" };
            Drain;
            ScrambleRemoteChunk { path = "a.txt"; index = 0 };
            RescanCorrupted;
            ListCorrupted;
            Delete "a.txt";
            Drain;
            Expire "all";
            Gc;
            RescanCorrupted;
            ListCorrupted;
          ];
      };
    ]
