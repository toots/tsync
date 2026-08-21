(* Collection scenarios: [expire] drops the references, [gc] reclaims the chunks
   that leaves unreferenced. Each snapshot's "backend" section is the point — a
   chunk listed there survived, one absent from it was reclaimed — and the
   "content" section is the check that matters, since a file whose chunks were
   wrongly reclaimed reads back as <unavailable>.

   Every scenario evicts before it finishes. Content is dumped by reading the file,
   and a cached file would read back happily with its chunk gone from the store,
   so without the evict a lost chunk would pass unnoticed.

   Nothing here spells a chunk key or a space: a scenario writes files and runs the
   two commands. See ../base/base.ml for the single-client harness and
   ../expire/expire.ml for the half that only drops references. *)

open Test_runner

let scenarios : scenario list =
  [
    {
      (* The pair of cases the whole thing exists for: the superseded version's
         chunk goes, the live file's chunk stays and the file still reads. *)
      name = "old version's chunk reclaimed, live chunk kept";
      steps =
        [
          Write { path = "foo.txt"; content = "one" };
          Drain;
          Write { path = "foo.txt"; content = "two two" };
          Drain;
          Expire "all";
          Gc;
          Evict "foo.txt";
        ];
    };
    {
      name = "deleted file fully reclaimed";
      steps =
        [
          Write { path = "foo.txt"; content = "gone soon" };
          Drain;
          Delete "foo.txt";
          Drain;
          Expire "all";
          Gc;
        ];
    };
    {
      name = "trashed folder fully reclaimed";
      steps =
        [
          Mkdir "d";
          Drain;
          Write { path = "d/a.txt"; content = "trash me" };
          Drain;
          Rmdir "d";
          Drain;
          Expire "all";
          Gc;
        ];
    };
    {
      (* Nothing expired, so nothing is unreferenced: a collection still has to
         leave every chunk in place. *)
      name = "nothing expired: every chunk kept";
      steps =
        [
          Write { path = "foo.txt"; content = "one" };
          Drain;
          Write { path = "foo.txt"; content = "two two" };
          Drain;
          Gc;
          Evict "foo.txt";
        ];
    };
    {
      (* The second collection finds nothing to do, rather than re-reclaiming or
         tripping over what the first left. *)
      name = "collecting again is a no-op";
      steps =
        [
          Write { path = "foo.txt"; content = "one" };
          Drain;
          Write { path = "foo.txt"; content = "two two" };
          Drain;
          Expire "all";
          Gc;
          Gc;
          Evict "foo.txt";
        ];
    };
    {
      (* The race this design exists to remove. [GcMark] leaves the collection
         open with every live chunk marked; the write that follows has the content
         of the file whose chunk was just orphaned, so the uploader deduplicates
         onto a chunk the collection had written off. Reading it back after the
         close is what proves publishing promoted it. *)
      name = "a write that deduplicates onto a doomed chunk survives";
      steps =
        [
          Write { path = "foo.txt"; content = "shared body" };
          Drain;
          Delete "foo.txt";
          Drain;
          Expire "all";
          GcMark;
          Write { path = "bar.txt"; content = "shared body" };
          Drain;
          GcClose;
          Evict "bar.txt";
        ];
    };
    {
      (* A plain write mid-collection: its chunk is new, so it lands in the space
         that survives and needs nothing done for it. *)
      name = "a write mid-collection survives";
      steps =
        [
          Write { path = "foo.txt"; content = "one" };
          Drain;
          Expire "all";
          GcMark;
          Write { path = "new.txt"; content = "written mid-collection" };
          Drain;
          GcClose;
          Evict "foo.txt";
          Evict "new.txt";
        ];
    };
    {
      (* Reading through an open collection: the body is still in the space on its
         way out, and a read has to find it there. *)
      name = "reading mid-collection finds the un-promoted body";
      steps =
        [
          Write { path = "foo.txt"; content = "read me while collecting" };
          Drain;
          Evict "foo.txt";
          GcMark;
          ReadRange { path = "foo.txt"; offset = 0; len = 24 };
          GcClose;
          Evict "foo.txt";
        ];
    };
    {
      (* Left open on purpose, so the snapshot shows the arrangement rather than
         only its outcome: the live chunk has been given a name in the surviving
         space, the orphan still has only its old one, and the file reads either
         way. Both spaces holding the same live chunk is the expected state — one
         inode, two names, and closing drops the old one. *)
      name = "mid-collection: the store in two spaces";
      steps =
        [
          Write { path = "foo.txt"; content = "one" };
          Drain;
          Write { path = "foo.txt"; content = "two two" };
          Drain;
          Expire "all";
          GcMark;
          Evict "foo.txt";
        ];
    };
    {
      (* Abandoning keeps everything, including what was about to be reclaimed. *)
      name = "abandoning a collection keeps every chunk";
      steps =
        [
          Write { path = "foo.txt"; content = "one" };
          Drain;
          Write { path = "foo.txt"; content = "two two" };
          Drain;
          Expire "all";
          GcMark;
          GcAbort;
          Evict "foo.txt";
        ];
    };
  ]

let () = run ~versioning:true scenarios
