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
      {
        name = "import with exclude by extension";
        steps =
          [
            ImportDirExclude
              {
                entries =
                  [
                    ("a.txt", "alpha");
                    ("b.tmp", "temp");
                    ("sub/c.txt", "charlie");
                    ("sub/d.tmp", "also temp");
                  ];
                exclude = ["*.tmp"];
              };
          ];
      };
      {
        name = "import special characters in filenames";
        steps =
          [
            ImportDir
              [
                ("colon:file.txt", "colons");
                ("dir:with:colons/nested.txt", "nested");
              ];
            Drain;
            ExportDir;
          ];
      };
      {
        name = "import with exclude directory";
        steps =
          [
            ImportDirExclude
              {
                entries =
                  [
                    ("a.txt", "alpha");
                    ("node_modules/lib.js", "big dep");
                    ("node_modules/deep/pkg.js", "nested dep");
                    ("src/main.ml", "code");
                  ];
                exclude = ["node_modules"];
              };
          ];
      };
      {
        name = "keep: symlink to file round-trips through export";
        steps =
          [
            ImportDirSymlinks
              {
                files = [("real.txt", "hello")];
                symlinks = [("link.txt", "real.txt")];
              };
            Drain;
            ExportDir;
          ];
      };
      {
        name = "keep: broken symlink is stored and exported as-is";
        steps =
          [
            ImportDirSymlinks
              { files = []; symlinks = [("dangling.txt", "nowhere")] };
            Drain;
            ExportDir;
          ];
      };
    ];

  run ~symlink_policy:`Follow
    [
      {
        name = "follow: dereferences file symlink";
        steps =
          [
            ImportDirSymlinks
              {
                files = [("real.txt", "hello")];
                symlinks = [("link.txt", "real.txt")];
              };
          ];
      };
      {
        name = "follow: skips broken symlink";
        steps =
          [
            ImportDirSymlinks
              { files = []; symlinks = [("dangling.txt", "nowhere")] };
          ];
      };
    ];

  run ~symlink_policy:`Skip
    [
      {
        name = "skip: all symlinks counted and skipped";
        steps =
          [
            ImportDirSymlinks
              {
                files = [("real.txt", "hello")];
                symlinks =
                  [("link.txt", "real.txt"); ("dangling.txt", "nowhere")];
              };
          ];
      };
    ]
