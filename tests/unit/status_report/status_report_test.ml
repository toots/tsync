(* Several processes, one machine, one report.

   Each answers about the domain it was asked about and about itself, and the
   same facts arrive more than once: a daemon serving two domains answers twice,
   two collectors both fetch the same mount, and a failure every process saw is
   logged by every process. What the fold has to do is say each of those once. *)

let answer ~frontend ~domain ~pid ?(serves = []) ?(warnings = []) ?(jobs = [])
    ?(domains = []) () =
  {
    Status_report.domain;
    frontend;
    socket_path = "/run/tsync-" ^ domain ^ ".sock";
    reply =
      `Assoc
        [
          ("ok", `Bool true);
          ( "server",
            `Assoc
              [
                ("hostname", `String "testhost");
                ("pid", `Int pid);
                ("uptimeSeconds", `Float 3720.);
                ("frontend", `String frontend);
                ( "serves",
                  `List
                    (List.map
                       (fun d -> `String d)
                       (if serves = [] then [domain] else serves)) );
              ] );
          ( "process",
            `Assoc
              [
                ("cpuSeconds", `Float 12.5);
                ("cpuPercentAvg", `Float 0.3);
                ("rssBytes", `Int 1048576);
                ("heapBytes", `Int 524288);
              ] );
          ( "traffic",
            `Assoc
              [
                ("bytesUploaded", `Int 2048);
                ("bytesDownloaded", `Int 4096);
                ("uploadBytesPerSec", `Int 0);
                ("downloadBytesPerSec", `Int 0);
                ("chunksHashed", `Int 5);
              ] );
          ("jobs", `List jobs);
          ( "recentErrors",
            `List
              (List.map
                 (fun (t, msg) ->
                   `Assoc
                     [
                       ("t", `Float t);
                       ("level", `String "warn");
                       ("message", `String msg);
                     ])
                 warnings) );
          ("domains", `List domains);
        ];
  }

let mount ~pid ~mount_point =
  `Assoc
    [
      ("type", `String "fuse");
      ("reachable", `Bool true);
      ("mountPoint", `String mount_point);
      ("stagedFiles", `Int 3);
      ("openHandles", `Int 2);
      ("filesOpened", `Int 41);
      ("pid", `Int pid);
    ]

let domain_body ~name ?(frontends = []) () =
  `Assoc
    [
      ("name", `String name);
      ("clientName", `String "testhost");
      ("versioning", `Bool true);
      ("symlinks", `String "keep");
      ("domainReadOnly", `Bool false);
      ("chunkSize", `Null);
      ("cacheChunkSize", `Int 16777216);
      ("maxCache", `Int 1073741824);
      ("maxUploads", `Int 4);
      ("maxChunkBuffers", `Int 4);
      ("maxDownloads", `Int 8);
      ("cache", `Assoc [("chunks", `Int 2); ("bytes", `Int 8192)]);
      ("wal", `Assoc [("pending", `Int 0)]);
      ("frontends", `List frontends);
      ( "backends",
        `List
          [
            `Assoc
              [
                ("name", `String "store");
                ("type", `String "local");
                ("role", `String "main");
                ("config", `Assoc [("path", `String "/srv/tsync")]);
                ("reachable", `Bool true);
                ("latencyMs", `Float 1.);
                ("journal", `Assoc [("entries", `Int 12); ("behind", `Int 0)]);
                ( "corrupted",
                  `Assoc [("checked", `Bool true); ("chunks", `Int 0)] );
              ];
          ] );
    ]

let job ~pid =
  `Assoc
    [
      ("kind", `String "import");
      ("pid", `Int pid);
      ("state", `String "running");
      ("uptimeSeconds", `Float 300.);
      ("target", `String "/media/stage");
    ]

let () =
  (* The converging process holds both domains and asks each frontend for its
     own figures. The fuse mount serving alpha reported the same job under both
     of the domains it answers for. *)
  let gathered =
    Status_report.of_answers
      ~local:
        [
          ( "server",
            `Assoc
              [
                ("hostname", `String "testhost");
                ("pid", `Int 4200);
                ("uptimeSeconds", `Float 3730.);
                ("frontend", `String "sync");
                ("serves", `List [`String "alpha"; `String "beta"]);
              ] );
          ( "process",
            `Assoc [("cpuPercentAvg", `Float 2.1); ("rssBytes", `Int 2097152)]
          );
          ( "recentErrors",
            `List
              [
                `Assoc
                  [
                    ("t", `Float 1700000030.);
                    ("level", `String "warn");
                    ("message", `String "store put: HTTP 429; retrying");
                  ];
              ] );
        ]
      ~domains:[domain_body ~name:"alpha" (); domain_body ~name:"beta" ()]
      [
        answer ~frontend:"fuse" ~domain:"alpha" ~pid:4242
          ~jobs:[job ~pid:9001]
          ~warnings:
            [
              (1700000010., "store put: HTTP 429; retrying");
              (1700000020., "store put: HTTP 429; retrying");
            ]
          ~domains:
            [
              `Assoc
                [
                  ("name", `String "alpha");
                  ( "frontends",
                    `List [mount ~pid:4242 ~mount_point:"/home/u/tsync/alpha"]
                  );
                ];
            ]
          ();
        answer ~frontend:"fuse" ~domain:"beta" ~pid:4243
          ~jobs:[job ~pid:9001]
          ~domains:
            [
              `Assoc
                [
                  ("name", `String "beta");
                  ( "frontends",
                    `List [mount ~pid:4243 ~mount_point:"/home/u/tsync/beta"] );
                ];
            ]
          ();
        (* Configured but not running. *)
        {
          (answer ~frontend:"http-proxy" ~domain:"alpha" ~pid:0 ()) with
          Status_report.reply = `Assoc [("error", `String "connection refused")];
        };
      ]
  in
  print_endline "########## the folded report ##########";
  print_endline (Yojson.Safe.pretty_to_string gathered);
  print_endline "########## as a reader sees it ##########";
  print_string (Status_report.text gathered);
  (* No converging process to ask: every frontend answers in full, and the
     bodies come from the answers instead of from the collector. *)
  let swept =
    Status_report.of_answers
      [
        answer ~frontend:"fuse" ~domain:"alpha" ~pid:4242
          ~serves:["alpha"; "beta"]
          ~domains:
            [
              domain_body ~name:"alpha"
                ~frontends:[mount ~pid:4242 ~mount_point:"/home/u/tsync/alpha"]
                ();
            ]
          ();
        answer ~frontend:"fuse" ~domain:"beta" ~pid:4242
          ~serves:["alpha"; "beta"]
          ~domains:
            [
              domain_body ~name:"beta"
                ~frontends:[mount ~pid:4242 ~mount_point:"/home/u/tsync/beta"]
                ();
            ]
          ();
      ]
  in
  print_endline
    "########## no converging process: the same fold over a sweep ##########";
  print_string (Status_report.text swept)
