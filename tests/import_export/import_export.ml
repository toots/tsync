(* Import/export scenarios. Import seeds a domain from a plain folder: data
   is uploaded to all backends, the cache gets manifest sidecars plus a
   symlink to the source data (files read as cached), and one journal entry
   announces everything. Export writes the whole domain to a folder: cached
   files are copied locally, evicted ones recomposed from remote chunks
   without repopulating the cache (visible as cached=false in the tree dump
   after export). *)

open Test_runner

let () =
  run
    [
      {
        name = "import into empty domain";
        steps =
          [
            ImportDir
              [
                ("a.txt", "alpha");
                ("sub/b.txt", "bravo");
                ("sub/deep/c.txt", "charlie");
              ];
          ];
      };
      {
        name = "import skips existing key";
        steps =
          [
            Write { path = "file.bin"; content = "original" };
            Drain;
            ImportDir [("file.bin", "imported"); ("new.txt", "fresh")];
          ];
      };
      {
        name = "import dedups identical content";
        steps =
          [
            Write { path = "file.bin"; content = "same bytes" };
            Drain;
            ImportDir [("copy.bin", "same bytes")];
          ];
      };
      {
        name = "export cached and evicted";
        steps =
          [
            Write { path = "cached.bin"; content = "kept locally" };
            Drain;
            Write { path = "evicted.bin"; content = "remote only" };
            Drain;
            Evict "evicted.bin";
            ExportDir;
          ];
      };
      {
        name = "export dirty file";
        steps =
          [
            Write { path = "file.bin"; content = "uploaded" };
            Drain;
            DirtyWrite { path = "file.bin"; content = "modified locally" };
            ExportDir;
          ];
      };
      {
        name = "import then export round trip";
        steps =
          [
            ImportDir [("a.txt", "alpha"); ("sub/b.txt", "bravo")];
            Drain;
            ExportDir;
          ];
      };
    ]
