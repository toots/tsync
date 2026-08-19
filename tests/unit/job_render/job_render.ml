(* What a reader is shown for a running command, in full.

   Every field reaches them through a format string that reads a name and a type
   it is given rather than ones it checks, and the rows are what someone reads
   at three in the morning to decide whether an import is stuck. A snapshot
   rather than a handful of substring assertions: the fragments an author
   thought to pin say nothing about the layout around them, and this way a
   reworded row shows up in the diff as the whole block it belongs to.

   Nothing here reads a clock — elapsed comes from the reporting process, whose
   clock is not the renderer's — so the output is the same on any machine. *)

let report fields =
  `Assoc
    [
      ("server", `Assoc [("frontend", `String "fuse")]);
      ("domains", `List []);
      ("jobs", `List [`Assoc fields]);
    ]

(* An import of a staging folder, a third of the way in. *)
let import ?error ?(progress = []) ~state () =
  report
    ([
       ("kind", `String "import");
       ("pid", `Int 4242);
       ("state", `String state);
       ("startedAt", `Float 1000.);
       ("uptimeSeconds", `Float 3720.);
       ("target", `String "/media/stage");
       ( "current",
         `String "Music Production/2024/sessions/live-takes/freedia0272.MXF" );
       ( "counters",
         `List
           [
             `List [`String "files"; `Int 30433];
             `List [`String "planned"; `Int 61956];
             `List [`String "skipped"; `Int 4];
             `List [`String "failed"; `Int 0];
           ] );
       ( "memory",
         `Assoc [("rssBytes", `Int 113246208); ("swappedBytes", `Int 41943040)]
       );
       ( "gc",
         `Assoc [("heapBytes", `Int 78643200); ("liveBytes", `Int 43008000)] );
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
             ("queued", `Int 207); ("inFlight", `Int 3); ("degraded", `Bool true);
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
           [("retries", `Int 91); ("timeouts", `Int 87); ("failures", `Int 0)]
       );
     ]
    @ progress
    @ match error with None -> [] | Some e -> [("error", `String e)])

(* A mirror of a domain the destination already holds, taken from a run in the
   field: an hour and a quarter in, eleven objects of two hundred thousand
   copied, and the bytes that moved are the rounding error of the bytes it got
   through. Its pools, its traffic and its counters are not an import's, and a
   row that reads like one is a row nobody checked. *)
let mirror ?(progress = []) () =
  report
    ([
       ("kind", `String "mirror");
       ("pid", `Int 112736);
       ("state", `String "running");
       ("startedAt", `Float 1000.);
       ("uptimeSeconds", `Float 4740.);
       ("target", `String "local");
       ( "current",
         `String
           "gcs · tsync/Files/chunks/41a/41a208a23b9e3d2a-21db2925f6924887" );
       ( "counters",
         `List
           [
             `List [`String "objects"; `Int 205432];
             `List [`String "planned"; `Int 225258];
             `List [`String "copied"; `Int 11];
           ] );
       ( "memory",
         `Assoc [("rssBytes", `Int 191365120); ("swappedBytes", `Int 253559194)]
       );
       ( "gc",
         `Assoc [("heapBytes", `Int 120268390); ("liveBytes", `Int 34707046)] );
       ( "traffic",
         `Assoc
           [
             ("bytesUploaded", `Int 59244544);
             ("uploadBytesPerSec", `Int 0);
             ("bytesDownloaded", `Int 0);
             ("downloadBytesPerSec", `Int 0);
             ("chunksHashed", `Int 0);
           ] );
       ( "deferred",
         `Assoc
           [("queued", `Int 0); ("inFlight", `Int 0); ("degraded", `Bool false)]
       );
       ( "pools",
         `List
           [
             `Assoc
               [
                 ("name", `String "copy");
                 ("inFlight", `Int 0);
                 ("max", `Int 4);
                 ("waiting", `Int 0);
               ];
             `Assoc
               [
                 ("name", `String "probe");
                 ("inFlight", `Int 16);
                 ("max", `Int 16);
                 ("waiting", `Int 48);
               ];
           ] );
       ( "backend",
         `Assoc
           [("retries", `Int 146); ("timeouts", `Int 146); ("failures", `Int 0)]
       );
     ]
    @ progress)

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
          ("ratedOn", `String "sent");
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
          ("ratedOn", `String "sent");
          ( "current",
            `Assoc
              [("bytesDone", `Int 536870912); ("bytesTotal", `Int 4294967296)]
          );
        ] );
  ]

(* 205432 objects of 225258 examined is 91% of the plan, and at that rate the
   fifth of an hour it has left is nine per cent of the hour and a quarter it
   has run: an estimate off what it copied would have said days. *)
let mirroring =
  [
    ( "progress",
      `Assoc
        [
          ("bytesTotal", `Int 966367641600);
          ("bytesDone", `Int 59244544);
          ("bytesSkipped", `Int 881255481344);
          ("bytesFailed", `Int 0);
          ("bytesHandled", `Int 881314725888);
          ("bytesRemaining", `Int 85052915712);
          ("bytesSent", `Int 59244544);
          ("etaSeconds", `Float 457.4);
        ] );
  ]

let show title json =
  Printf.printf "=== %s\n%s\n" title (jobs_block (Diagnostics.text json))

let () =
  show "a running import, with the bytes it has behind and ahead of it"
    (import ~state:"running" ~progress:resumed ());
  (* A command that counts entries and not bytes reports no progress at all,
     which must render as a job without that row rather than as an empty one. *)
  show "a command that counts entries and not bytes"
    (import ~state:"running" ());
  show "a run that has hashed its way through stored chunks, sending nothing"
    (import ~state:"running" ~progress:deduplicating ());
  (* Nothing is moving at the rate this estimate divides by, and the traffic row
     two lines down says what did move. *)
  show "a mirror, whose estimate is against what it got through"
    (mirror ~progress:mirroring ());
  (* The elapsed figure is the same either way, so a job that has stopped must
     not leave it reading as an age. *)
  show "a job that died, which is the only trace its process leaves"
    (import ~state:"failed" ~error:"disk full" ())
