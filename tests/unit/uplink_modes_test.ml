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

let field path j =
  List.fold_left
    (fun j k ->
      match j with
        | `Assoc l -> List.assoc_opt k l |> Option.value ~default:`Null
        | _ -> `Null)
    j path

let mode link = field [link; "mode"] (Uplink.status ())

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
  `Assoc
    [
      ("ok", `Bool true);
      ("interval", `Float 2.);
      ("links", `Assoc [("wan", `Assoc [("rate", `Float rate)])]);
    ]

let () =
  Rt.run_sync (fun () ->
      let wan = Uplink.link "wan" settings
      and lan = Uplink.link "lan" settings in
      let answer = ref (`Grant 1e6) and calls = ref 0 and last = ref `Null in
      Uplink.lease (fun req ->
          incr calls;
          last := req;
          match !answer with
            | `Grant r -> grant r
            | `Refuse -> `Assoc [("ok", `Bool true)]
            | `Fail -> failwith "unreached");
      use wan;
      use lan;
      p "== lessee";
      p "granted: %b"
        (until (fun () -> mode "wan" = `String "leased" && !calls > 0));
      p "one request renews every link: %s"
        (match field ["links"] !last with
          | `Assoc l -> String.concat ", " (List.sort compare (List.map fst l))
          | _ -> "none");
      let rate l =
        Yojson.Safe.to_string (field [l; "rateBytesPerSec"] (Uplink.status ()))
      in
      p "wan granted %s; lan, not named, keeps %s" (rate "wan") (rate "lan");
      answer := `Fail;
      let c = !calls in
      ignore (until (fun () -> !calls >= c + 2));
      p "two missed renewals: %s" (Yojson.Safe.to_string (mode "wan"));
      p "the third makes it local: %b"
        (until (fun () -> mode "wan" = `String "local"));
      answer := `Grant 1e6;
      Uplink.lease (fun req ->
          incr calls;
          last := req;
          match !answer with
            | `Grant r -> grant r
            | `Refuse -> `Assoc [("ok", `Bool true)]
            | `Fail -> failwith "unreached");
      ignore (until (fun () -> mode "wan" = `String "leased"));
      answer := `Refuse;
      p "a refusal makes it local at once: %b"
        (let c = !calls in
         until (fun () -> !calls > c) && mode "wan" = `String "local");
      p "== owner";
      Uplink.own (fun _ -> settings);
      let me = Unix.getpid () in
      let report pid =
        `Assoc
          [
            ("action", `String "uplink");
            ("pid", `Int pid);
            ( "links",
              `Assoc
                [
                  ( "wan",
                    `Assoc
                      [
                        ("inFlight", `Int 1000);
                        ("completed", `Int 0);
                        ("waiting", `Int 2);
                        ("heldBack", `Bool true);
                        ("probesMs", `Assoc [("gcs", `Float 40.)]);
                      ] );
                ] );
          ]
      in
      let rate j = field ["links"; "wan"; "rate"] j in
      (match Uplink.renewal (report me) with
        | Some a ->
            p "a newcomer is answered from an immediate split: %s"
              (match rate a with
                | `Float r -> Printf.sprintf "%.0f of %.0f" r (256. *. 1024.)
                | _ -> "no grant")
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
        match field ["wan"; "lessees"] (Uplink.status ()) with
          | `List l -> List.length l
          | _ -> -1
      in
      p "two lessees recorded: %d" (lessees ());
      p "the row of a gone pid is dropped at the next step: %b"
        (until (fun () -> lessees () = 1));
      p "a flat report of an older build is answered with a top-level rate: %b"
        (match
           Uplink.renewal
             (`Assoc
                [
                  ("action", `String "uplink");
                  ("pid", `Int me);
                  ("inFlight", `Int 0);
                ])
         with
          | Some (`Assoc l) ->
              List.mem_assoc "rate" l && List.mem_assoc "links" l
          | _ -> false);
      Stop.request ())
