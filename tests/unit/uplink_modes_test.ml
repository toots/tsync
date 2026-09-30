open Tsync_core
open Tsync_store

let p fmt = Printf.printf (fmt ^^ "\n%!")

let settings =
  {
    Uplink.enabled = true;
    law =
      {
        headroom = 0.8;
        target_delay = 0.05;
        min_rate = 64. *. 1024.;
        max_rate = None;
      };
  }

let link_status name =
  List.find_opt
    (fun (l : Uplink.link_status) -> l.name = name)
    (Uplink.status ())

let mode name =
  match link_status name with
    | Some { mode = `Owner; _ } -> "owner"
    | Some { mode = `Leased; _ } -> "leased"
    | Some { mode = `Local; _ } -> "local"
    | None -> "dormant"

(* The ticker runs on the real clock: wait for a condition, bounded. *)
let until ?(limit = 15.) cond =
  let deadline = Rt.now () +. limit in
  let rec go () =
    if cond () then true
    else if Rt.now () > deadline then false
    else (
      Rt.sleep 0.1;
      go ())
  in
  go ()

let use link = Uplink.completed link (Uplink.acquire link 1000)

let grant rate =
  Some
    {
      Uplink_lease.interval = 2.;
      grants = [("wan", { rate; limit = Measured })];
      flat = false;
    }

let () =
  Rt.run_sync (fun () ->
      let wan = Uplink.link "wan" settings
      and lan = Uplink.link "lan" settings in
      let answer = ref (`Grant 1e6) and calls = ref 0 and last = ref None in
      Uplink.lease (fun req ->
          incr calls;
          last := Some req;
          match !answer with
            | `Grant r -> grant r
            | `Refuse -> None
            | `Fail -> failwith "unreached");
      use wan;
      use lan;
      p "== lessee";
      p "granted: %b" (until (fun () -> mode "wan" = "leased" && !calls > 0));
      p "one request renews every link: %s"
        (match !last with
          | Some (r : Uplink_lease.request) ->
              String.concat ", " (List.sort compare (List.map fst r.links))
          | None -> "none");
      let rate l =
        Option.fold ~none:"?"
          ~some:(fun (s : Uplink.link_status) -> Printf.sprintf "%.1f" s.rate)
          (link_status l)
      in
      p "wan granted %s; lan, not named, keeps %s" (rate "wan") (rate "lan");
      answer := `Fail;
      let c = !calls in
      ignore (until (fun () -> !calls >= c + 2));
      p "two missed renewals: %S" (mode "wan");
      p "the third makes it local: %b" (until (fun () -> mode "wan" = "local"));
      answer := `Grant 1e6;
      Uplink.lease (fun req ->
          incr calls;
          last := Some req;
          match !answer with
            | `Grant r -> grant r
            | `Refuse -> None
            | `Fail -> failwith "unreached");
      ignore (until (fun () -> mode "wan" = "leased"));
      answer := `Refuse;
      p "a refusal makes it local at once: %b"
        (let c = !calls in
         until (fun () -> !calls > c) && mode "wan" = "local");
      p "== owner";
      Uplink.own (fun _ -> settings);
      let me = Unix.getpid () in
      let report pid =
        {
          Uplink_lease.pid;
          links =
            [
              ( "wan",
                {
                  Uplink_lease.idle with
                  in_flight = 1000;
                  waiting = 2;
                  held_back = true;
                  probes = [("gcs", 0.04)];
                } );
            ];
          flat = false;
        }
      in
      (match Uplink.renewal (report me) with
        | Some a ->
            p "a newcomer is answered from an immediate split: %s"
              (match List.assoc_opt "wan" a.grants with
                | Some g -> Printf.sprintf "%.0f of %.0f" g.rate (256. *. 1024.)
                | None -> "no grant")
        | None -> p "refused");
      let dead =
        let pid =
          Unix.create_process "true" [| "true" |] Unix.stdin Unix.stdout
            Unix.stderr
        in
        ignore (Unix.waitpid [] pid);
        pid
      in
      ignore (Uplink.renewal (report dead));
      let lessees () =
        Option.fold ~none:(-1)
          ~some:(fun (s : Uplink.link_status) -> List.length s.lessees)
          (link_status "wan")
      in
      p "two lessees recorded: %d" (lessees ());
      p "the row of a gone pid is dropped at the next step: %b"
        (until (fun () -> lessees () = 1));
      p "a flat report of an older build is answered with a top-level rate: %b"
        (match
           Option.bind
             (Uplink_lease.request_of_json
                (`Assoc
                   [
                     ("action", `String "uplink");
                     ("pid", `Int me);
                     ("inFlight", `Int 0);
                   ]))
             Uplink.renewal
         with
          | Some a -> (
              match Uplink_lease.answer_to_json a with
                | `Assoc l ->
                    List.mem_assoc "rate" l && List.mem_assoc "links" l
                | _ -> false)
          | None -> false);
      Stop.request ())
