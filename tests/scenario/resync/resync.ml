(* Writes fan out to both backends, damage is injected on the secondary
   (OnSecondary ...), then ResyncRemote copies whatever is missing or
   size-mismatched from the primary. Snapshots show the copied keys and both
   buckets, manifest contents included. *)

open Test_runner

let () =
  run
    [
      {
        name = "mirror in sync";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            ResyncRemote;
          ];
      };
      {
        name = "mirror heals missing chunk on secondary";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            OnSecondary (DeleteRemoteChunk { path = "file.bin"; index = 0 });
            ResyncRemote;
            ResyncRemote;
          ];
      };
      {
        name = "mirror heals corrupt chunk on secondary";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            OnSecondary (CorruptRemoteChunk { path = "file.bin"; index = 0 });
            ResyncRemote;
          ];
      };
      {
        name = "mirror heals missing manifest on secondary";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            OnSecondary (DeleteRemoteManifest "file.bin");
            ResyncRemote;
          ];
      };
      {
        (* Same length, different bytes: a size comparison sees nothing, and
           this one deliberately looks no further. Holding a chunk against its
           own name is the store's job, read back through tsync data-integrity.
        *)
        name = "mirror leaves a scrambled chunk alone";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            OnSecondary (ScrambleRemoteChunk { path = "file.bin"; index = 0 });
            ResyncRemote;
          ];
      };
      {
        name = "mirror --path copies one folder and its chunks";
        steps =
          [
            Write { path = "outside.bin"; content = "not this one" };
            Mkdir "keep";
            Write { path = "keep/inside.bin"; content = "this one" };
            Drain;
            OnSecondary (DeleteRemoteChunk { path = "outside.bin"; index = 0 });
            OnSecondary
              (DeleteRemoteChunk { path = "keep/inside.bin"; index = 0 });
            ResyncScoped { path = Some "keep" };
          ];
      };
      {
        name = "mirror heals mixed tree on secondary";
        steps =
          [
            Write { path = "ok.bin"; content = "fine" };
            Drain;
            Mkdir "sub";
            Write { path = "sub/nested.bin"; content = "nested" };
            Drain;
            OnSecondary (DeleteRemoteChunk { path = "ok.bin"; index = 0 });
            OnSecondary (DeleteRemoteManifest "sub/nested.bin");
            ResyncRemote;
          ];
      };
    ]
