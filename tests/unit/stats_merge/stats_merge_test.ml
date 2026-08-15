(* A daemon serving several domains answers for the one it was asked about, so
   [tsync status] asks once per domain and folds the answers back into the single
   report that daemon would have given: the domains stack up, the process
   figures above them are stated once. *)

let member = Yojson.Safe.Util.member

let report ~domain =
  `Assoc
    [
      ("ok", `Bool true);
      ( "server",
        `Assoc
          [
            ("hostname", `String "testhost");
            ("pid", `Int 4242);
            ("uptimeSeconds", `Float 3720.);
            ("frontend", `String "fuse");
            ("serves", `List [`String domain]);
          ] );
      ( "process",
        `Assoc
          [
            ("cpuSeconds", `Float 12.5);
            ("cpuPercentAvg", `Float 0.3);
            ("rssBytes", `Int 1048576);
            ("heapBytes", `Int 524288);
            ("topHeapBytes", `Int 786432);
            ("minorCollections", `Int 7);
            ("majorCollections", `Int 2);
          ] );
      ( "lwt",
        `Assoc
          [
            ("readableFds", `Int 3);
            ("writableFds", `Int 0);
            ("timers", `Int 4);
            ("poolSize", `Int 8);
          ] );
      ( "traffic",
        `Assoc
          [
            ("bytesUploaded", `Int 2048);
            ("bytesDownloaded", `Int 4096);
            ("uploadBytesPerSec", `Int 0);
            ("downloadBytesPerSec", `Int 0);
            ("chunksHashed", `Int 5);
            ("hashesPerSec", `Int 0);
          ] );
      ( "domains",
        `List
          [
            `Assoc
              [
                ("name", `String domain);
                ("clientName", `String "testhost");
                ("versioning", `Bool true);
                ("symlinks", `String "keep");
                ("maxUploads", `Int 4);
                ("maxChunkBuffers", `Int 4);
                ("maxDownloads", `Int 8);
                ("cacheRoot", `String "/cache");
                ("socketPath", `String ("/run/tsync-" ^ domain ^ ".sock"));
                ("cache", `Assoc [("chunks", `Int 2); ("bytes", `Int 8192)]);
              ];
          ] );
    ]

let () =
  let alpha = report ~domain:"alpha" and beta = report ~domain:"beta" in
  let merged = Diagnostics.merge [alpha; beta] in
  (match member "domains" merged with
    | `List domains ->
        assert (
          List.map (member "name") domains = [`String "alpha"; `String "beta"])
    | _ -> assert false);
  (* The header names every domain below it, not just the first answer's. *)
  assert (
    member "serves" (member "server" merged)
    = `List [`String "alpha"; `String "beta"]);
  (* The process is one process: its figures are taken, not summed. *)
  assert (member "pid" (member "server" merged) = `Int 4242);
  assert (member "traffic" merged = member "traffic" alpha);
  (* A lone answer renders as it did before there was anything to merge. *)
  assert (Diagnostics.text (Diagnostics.merge [alpha]) = Diagnostics.text alpha);
  print_endline "########## two domains, one daemon ##########";
  print_string (Diagnostics.text merged)
