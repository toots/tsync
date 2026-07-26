(* Recheck scenarios: verify and repair remote chunks and manifests from the
   local cache. Backend damage is injected behind the daemon's back
   (DeleteRemoteChunk / CorruptRemoteChunk / DeleteRemoteManifest); each
   snapshot shows the per-file recheck lines and the resulting bucket state,
   including full manifest contents. *)

open Test_runner

let () =
  run
    [
      {
        name = "recheck healthy";
        steps =
          [Write { path = "file.bin"; content = "hello world" }; Drain; Recheck];
      };
      {
        name = "recheck repairs missing chunk";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            DeleteRemoteChunk { path = "file.bin"; index = 0 };
            Recheck;
            Recheck;
          ];
      };
      {
        name = "recheck repairs corrupt chunk";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            CorruptRemoteChunk { path = "file.bin"; index = 0 };
            Recheck;
          ];
      };
      {
        name = "recheck republishes missing manifest";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            DeleteRemoteManifest "file.bin";
            Recheck;
          ];
      };
      {
        name = "a corrupt cached chunk is dropped, then re-fetched on read";
        steps =
          [
            Write { path = "file.bin"; content = "old content" };
            Drain;
            CorruptCachedChunk { path = "file.bin"; index = 0 };
            Recheck;
            Recheck;
          ];
      };
      {
        name = "recheck skips a file with unsynced edits";
        steps =
          [
            Write { path = "file.bin"; content = "uploaded" };
            Drain;
            StageWrite { path = "file.bin"; content = "not yet uploaded" };
            Recheck;
          ];
      };
      {
        name = "recheck a file with nothing cached";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            Evict "file.bin";
            Recheck;
          ];
      };
      {
        name = "recheck evicted missing manifest";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            Evict "file.bin";
            DeleteRemoteManifest "file.bin";
            Recheck;
          ];
      };
      {
        name = "recheck evicted missing chunk";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            Evict "file.bin";
            DeleteRemoteChunk { path = "file.bin"; index = 0 };
            Recheck;
          ];
      };
      {
        name = "recheck evicted chunk and manifest gone";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            Evict "file.bin";
            DeleteRemoteChunk { path = "file.bin"; index = 0 };
            DeleteRemoteManifest "file.bin";
            Recheck;
          ];
      };
      {
        name = "recheck mixed tree";
        steps =
          [
            Write { path = "ok.bin"; content = "fine" };
            Drain;
            Mkdir "sub";
            Write { path = "sub/nested.bin"; content = "nested" };
            Drain;
            Write { path = "broken.bin"; content = "damaged" };
            Drain;
            Evict "broken.bin";
            DeleteRemoteChunk { path = "broken.bin"; index = 0 };
            Recheck;
          ];
      };
    ]
