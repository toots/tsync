(* What a reader is shown for each of a domain's stores.

   A snapshot rather than substring assertions, for the reason
   {!Tests.Unit.Job_render} gives: a fragment an author thought to pin says
   nothing about the rows around it, and a reworded row should show up in the
   diff as the block it belongs to.

   The question these rows answer is which link a transfer is on. A domain whose
   replica is the slow one looks exactly like a domain whose main is, in the
   process-wide traffic figure that used to be the only one. *)

let backend ?traffic ?deferred ~name ~typ ~role () =
  `Assoc
    ([
       ("name", `String name);
       ("type", `String typ);
       ("role", `String role);
       ("config", `Assoc [("bucket", `String ("tsync-" ^ name))]);
       ("reachable", `Bool true);
       ("latencyMs", `Float 138.);
       ( "journal",
         `Assoc
           [
             ("entries", `Int 135);
             ("behind", `Int 0);
             ("truncated", `Bool false);
           ] );
       ("corrupted", `Assoc [("checked", `Bool true); ("chunks", `Int 0)]);
     ]
    @ (match traffic with None -> [] | Some t -> [("traffic", t)])
    @ match deferred with None -> [] | Some d -> [("deferred", d)])

let traffic ~up ~up_rate ~down ~down_rate =
  `Assoc
    [
      ("bytesUploaded", `Int up);
      ("bytesDownloaded", `Int down);
      ("uploadBytesPerSec", `Int up_rate);
      ("downloadBytesPerSec", `Int down_rate);
    ]

let domain backends =
  `Assoc
    [
      ("server", `Assoc [("frontend", `String "fuse")]);
      ("jobs", `List []);
      ( "domains",
        `List
          [
            `Assoc
              [
                ("name", `String "Files");
                ("clientName", `String "droppy");
                ("backends", `List backends);
              ];
          ] );
    ]

(* The domain block's own rows are the job renderer's business, not this one's:
   everything from the first store onwards is what these cases are about. *)
let backends_block text =
  let lines = String.split_on_char '\n' text in
  let rec from_first = function
    | [] -> []
    | l :: rest ->
        if String.starts_with ~prefix:"  Backend " l then l :: rest
        else from_first rest
  in
  String.concat "\n" (from_first lines)

let show title json =
  Printf.printf "=== %s\n%s\n" title (backends_block (Status_report.text json))

let () =
  show "a store with a link, whose bytes and rates are its own"
    (domain
       [
         backend ~name:"gcs" ~typ:"gcs" ~role:"replica"
           ~traffic:
             (traffic ~up:487139078144 ~up_rate:25100 ~down:1048576
                ~down_rate:46137)
           ();
       ]);
  (* A filesystem has no link to cross, so it prints no row at all: a pair of
     zeros would read as a store that is idle rather than one that never had
     traffic to report. *)
  show "a local store, which is a filesystem rather than a link"
    (domain [backend ~name:"local" ~typ:"local" ~role:"main" ()]);
  (* The figure exists to tell one store's throughput from another's, which a
     domain reporting a single process-wide number cannot. *)
  show "two stores, each with its own"
    (domain
       [
         backend ~name:"local" ~typ:"local" ~role:"main" ();
         backend ~name:"gcs" ~typ:"gcs" ~role:"replica"
           ~traffic:
             (traffic ~up:487139078144 ~up_rate:25100 ~down:1048576
                ~down_rate:46137)
           ~deferred:
             (`Assoc
                [
                  ("queued", `Int 99100);
                  ("inFlight", `Int 0);
                  ("degraded", `Bool true);
                ])
           ();
       ]);
  (* A store that has a link but has moved nothing over it still reports, since
     zero here is a fact about the transfer rather than about the store. *)
  show "a store that has a link and has used none of it"
    (domain
       [
         backend ~name:"gcs" ~typ:"gcs" ~role:"replica"
           ~traffic:(traffic ~up:0 ~up_rate:0 ~down:0 ~down_rate:0)
           ();
       ])
