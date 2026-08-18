(* What a reader is shown for a running command, in full.

   Every field reaches them through a format string that reads a name and a type
   it is given rather than ones it checks, and the rows are what someone reads
   at three in the morning to decide whether an import is stuck. A snapshot
   rather than a handful of substring assertions: the fragments an author
   thought to pin say nothing about the layout around them, and this way a
   reworded row shows up in the diff as the whole block it belongs to.

   Nothing here reads a clock — elapsed comes from the reporting process, whose
   clock is not the renderer's — so the output is the same on any machine. *)

let job ?error ?(progress = []) ~state () =
  `Assoc
    [
      ("server", `Assoc [("frontend", `String "fuse")]);
      ("domains", `List []);
      ( "jobs",
        `List
          [
            `Assoc
              ([
                 ("kind", `String "import");
                 ("pid", `Int 4242);
                 ("state", `String state);
                 ("startedAt", `Float 1000.);
                 ("uptimeSeconds", `Float 3720.);
                 ("target", `String "/media/stage");
                 ( "current",
                   `String
                     "Music Production/2024/sessions/live-takes/freedia0272.MXF"
                 );
                 ( "counters",
                   `List
                     [
                       `List [`String "files"; `Int 30433];
                       `List [`String "planned"; `Int 61956];
                       `List [`String "skipped"; `Int 4];
                       `List [`String "failed"; `Int 0];
                     ] );
                 ( "memory",
                   `Assoc
                     [
                       ("rssBytes", `Int 113246208);
                       ("swappedBytes", `Int 41943040);
                     ] );
                 ( "gc",
                   `Assoc
                     [
                       ("heapBytes", `Int 78643200); ("liveBytes", `Int 43008000);
                     ] );
                 ( "traffic",
                   `Assoc
                     [
                       ("bytesUploaded", `Int 756640839270);
                       ("uploadBytesPerSec", `Int 8178892);
                       ("bytesDownloaded", `Int 41231872);
                       ("downloadBytesPerSec", `Int 2097152);
                       ("chunksHashed", `Int 2500);
                     ] );
                 ( "deferred",
                   `Assoc
                     [
                       ("queued", `Int 207);
                       ("inFlight", `Int 3);
                       ("degraded", `Bool true);
                     ] );
                 ( "pools",
                   `List
                     [
                       `Assoc
                         [
                           ("name", `String "chunk buffers");
                           ("inFlight", `Int 4);
                           ("max", `Int 4);
                           ("waiting", `Int 12);
                         ];
                     ] );
                 ( "backend",
                   `Assoc
                     [
                       ("retries", `Int 91);
                       ("timeouts", `Int 87);
                       ("failures", `Int 0);
                     ] );
               ]
              @ progress
              @ match error with None -> [] | Some e -> [("error", `String e)]);
          ] );
    ]

(* A resumed import: most of its tree was already in the domain, so a fraction
   of what it uploaded would read 14% for a run that is 39% through. *)
let resumed =
  [
    ( "progress",
      `Assoc
        [
          ("bytesTotal", `Int 9019431322);
          ("bytesDone", `Int 1288490188);
          ("bytesSkipped", `Int 2254857830);
          ("bytesFailed", `Int 0);
          ("bytesHandled", `Int 3543348018);
          ("bytesRemaining", `Int 5476083304);
          ("bytesPerSecAvg", `Int 8178892);
          ("etaSeconds", `Float 669.5);
          ( "current",
            `Assoc
              [("bytesDone", `Int 536870912); ("bytesTotal", `Int 4294967296)]
          );
        ] );
  ]

(* The frontend's own block opens every report and says nothing about a job, so
   a snapshot of three cases would otherwise be three copies of it. *)
let jobs_block text =
  let rec drop = function
    | [] -> []
    | "Jobs" :: rest -> rest
    | _ :: rest -> drop rest
  in
  String.concat "\n" (drop (String.split_on_char '\n' text))

(* A restart re-hashing what it already stored: every chunk deduplicates, so
   nothing is transferred and there is no throughput to extrapolate from. *)
let deduplicating =
  [
    ( "progress",
      `Assoc
        [
          ("bytesTotal", `Int 9019431322);
          ("bytesDone", `Int 536870912);
          ("bytesSkipped", `Int 2254857830);
          ("bytesFailed", `Int 0);
          ("bytesHandled", `Int 2791728742);
          ("bytesRemaining", `Int 6227702580);
          ("bytesSent", `Int 0);
          ("bytesPerSecAvg", `Int 0);
          ( "current",
            `Assoc
              [("bytesDone", `Int 536870912); ("bytesTotal", `Int 4294967296)]
          );
        ] );
  ]

let show title json =
  Printf.printf "=== %s\n%s\n" title (jobs_block (Diagnostics.text json))

let () =
  show "a running import, with the bytes it has behind and ahead of it"
    (job ~state:"running" ~progress:resumed ());
  (* A command that counts entries and not bytes reports no progress at all,
     which must render as a job without that row rather than as an empty one. *)
  show "a command that counts entries and not bytes" (job ~state:"running" ());
  show "a run that has hashed its way through stored chunks, sending nothing"
    (job ~state:"running" ~progress:deduplicating ());
  (* The elapsed figure is the same either way, so a job that has stopped must
     not leave it reading as an age. *)
  show "a job that died, which is the only trace its process leaves"
    (job ~state:"failed" ~error:"disk full" ())
