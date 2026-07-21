open Test_runner

let () =
  run
    [
      {
        name = "import into empty domain";
        steps =
          [
            LocalWrite { path = "a.txt"; content = "alpha" };
            LocalWrite { path = "sub/b.txt"; content = "bravo" };
            LocalWrite { path = "sub/deep/c.txt"; content = "charlie" };
            Import { only = []; exclude = []; force_rehash = false };
          ];
      };
      {
        name = "import skips existing key";
        steps =
          [
            Write { path = "file.bin"; content = "original" };
            Drain;
            LocalWrite { path = "file.bin"; content = "imported" };
            LocalWrite { path = "new.txt"; content = "fresh" };
            Import { only = []; exclude = []; force_rehash = false };
          ];
      };
      {
        name = "import dedups identical content";
        steps =
          [
            Write { path = "file.bin"; content = "same bytes" };
            Drain;
            LocalWrite { path = "copy.bin"; content = "same bytes" };
            Import { only = []; exclude = []; force_rehash = false };
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
            LocalWrite { path = "a.txt"; content = "alpha" };
            LocalWrite { path = "sub/b.txt"; content = "bravo" };
            Import { only = []; exclude = []; force_rehash = false };
            Drain;
            ExportDir;
          ];
      };
      {
        name = "import with exclude by extension";
        steps =
          [
            LocalWrite { path = "a.txt"; content = "alpha" };
            LocalWrite { path = "b.tmp"; content = "temp" };
            LocalWrite { path = "sub/c.txt"; content = "charlie" };
            LocalWrite { path = "sub/d.tmp"; content = "also temp" };
            Import { only = []; exclude = ["*.tmp"]; force_rehash = false };
          ];
      };
      {
        name = "force-rehash republishes unchanged file";
        steps =
          [
            LocalWrite { path = "file.bin"; content = "hello world" };
            Import { only = []; exclude = []; force_rehash = false };
            LocalWrite { path = "file.bin"; content = "hello world" };
            Import { only = []; exclude = []; force_rehash = true };
          ];
      };
      {
        name = "force-rehash re-uploads missing chunk";
        steps =
          [
            LocalWrite { path = "file.bin"; content = "hello world" };
            Import { only = []; exclude = []; force_rehash = false };
            DeleteRemoteChunk { path = "file.bin"; index = 0 };
            LocalWrite { path = "file.bin"; content = "hello world" };
            Import { only = []; exclude = []; force_rehash = true };
          ];
      };
      {
        name = "force-rehash picks up changed content";
        steps =
          [
            LocalWrite { path = "file.bin"; content = "original content" };
            Import { only = []; exclude = []; force_rehash = false };
            LocalWrite { path = "file.bin"; content = "updated content" };
            Import { only = []; exclude = []; force_rehash = true };
          ];
      };
      {
        name = "import with non-empty and empty directories";
        steps =
          [
            LocalWrite { path = "non-empty/file.txt"; content = "hello" };
            LocalMkdir "empty-dir";
            Import { only = []; exclude = []; force_rehash = false };
          ];
      };
      {
        name = "import special characters in filenames";
        steps =
          [
            LocalWrite { path = "colon:file.txt"; content = "colons" };
            LocalWrite
              { path = "dir:with:colons/nested.txt"; content = "nested" };
            Import { only = []; exclude = []; force_rehash = false };
            Drain;
            ExportDir;
          ];
      };
      {
        name = "import with only by extension";
        steps =
          [
            LocalWrite { path = "a.txt"; content = "alpha" };
            LocalWrite { path = "b.tmp"; content = "temp" };
            LocalWrite { path = "sub/c.txt"; content = "charlie" };
            LocalWrite { path = "sub/d.tmp"; content = "also temp" };
            Import { only = ["*.txt"]; exclude = []; force_rehash = false };
          ];
      };
      {
        name = "import with only directory imports its contents";
        steps =
          [
            LocalWrite { path = "keep/a.txt"; content = "alpha" };
            LocalWrite { path = "keep/deep/b.txt"; content = "bravo" };
            LocalWrite { path = "drop/c.txt"; content = "charlie" };
            Import { only = ["keep"]; exclude = []; force_rehash = false };
          ];
      };
      {
        name = "import only then exclude on top";
        steps =
          [
            LocalWrite { path = "keep/a.txt"; content = "alpha" };
            LocalWrite { path = "keep/b.tmp"; content = "temp" };
            LocalWrite { path = "drop/c.txt"; content = "charlie" };
            Import
              { only = ["keep"]; exclude = ["*.tmp"]; force_rehash = false };
          ];
      };
      {
        name = "import with exclude directory";
        steps =
          [
            LocalWrite { path = "a.txt"; content = "alpha" };
            LocalWrite { path = "node_modules/lib.js"; content = "big dep" };
            LocalWrite
              { path = "node_modules/deep/pkg.js"; content = "nested dep" };
            LocalWrite { path = "src/main.ml"; content = "code" };
            Import
              { only = []; exclude = ["node_modules"]; force_rehash = false };
          ];
      };
      {
        name = "keep: symlink to file round-trips through export";
        steps =
          [
            LocalWrite { path = "real.txt"; content = "hello" };
            LocalSymlink { path = "link.txt"; target = "real.txt" };
            Import { only = []; exclude = []; force_rehash = false };
            Drain;
            ExportDir;
          ];
      };
      {
        name = "keep: broken symlink is stored and exported as-is";
        steps =
          [
            LocalSymlink { path = "dangling.txt"; target = "nowhere" };
            Import { only = []; exclude = []; force_rehash = false };
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
            LocalWrite { path = "real.txt"; content = "hello" };
            LocalSymlink { path = "link.txt"; target = "real.txt" };
            Import { only = []; exclude = []; force_rehash = false };
          ];
      };
      {
        name = "follow: skips broken symlink";
        steps =
          [
            LocalSymlink { path = "dangling.txt"; target = "nowhere" };
            Import { only = []; exclude = []; force_rehash = false };
          ];
      };
    ];

  run ~symlink_policy:`Skip
    [
      {
        name = "skip: all symlinks counted and skipped";
        steps =
          [
            LocalWrite { path = "real.txt"; content = "hello" };
            LocalSymlink { path = "link.txt"; target = "real.txt" };
            LocalSymlink { path = "dangling.txt"; target = "nowhere" };
            Import { only = []; exclude = []; force_rehash = false };
          ];
      };
    ]
