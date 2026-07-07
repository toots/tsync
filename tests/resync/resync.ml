(* Remote-resync scenarios: writes fan out to both backends, damage is
   injected on the secondary (OnSecondary ...), then ResyncRemote copies
   whatever is missing or size-mismatched there from the primary. Snapshots
   show the copied keys and both buckets, including manifest contents. *)

open Test_runner

let () =
  run
    [
      {
        name = "resync-remote in sync";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            ResyncRemote;
          ];
      };
      {
        name = "resync-remote heals missing chunk on secondary";
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
        name = "resync-remote heals corrupt chunk on secondary";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            OnSecondary (CorruptRemoteChunk { path = "file.bin"; index = 0 });
            ResyncRemote;
          ];
      };
      {
        name = "resync-remote heals missing manifest on secondary";
        steps =
          [
            Write { path = "file.bin"; content = "hello world" };
            Drain;
            OnSecondary (DeleteRemoteManifest "file.bin");
            ResyncRemote;
          ];
      };
      {
        name = "resync-remote heals mixed tree on secondary";
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
