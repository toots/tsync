(* The conformance suite of menu-model.md §8: fixed replies in, everything a
   user reads out. *)
open Tsync_menu
module M = Menu_model

let cases = ref 0

let case title =
  incr cases;
  Printf.printf "\n== %s\n" title

let action = function
  | M.Nothing -> ""
  | Open_folder d -> " -> open " ^ d
  | Reveal { domain; rel } -> Printf.sprintf " -> reveal %s:%s" domain rel
  | Set_paused p -> Printf.sprintf " -> pause %b" p
  | Show_stats | Show_codes -> ""
  | Copy_code { domain; id } -> Printf.sprintf " -> copy %s:%s" domain id
  | Unlock d -> " -> unlock " ^ d
  | Add_code d -> " -> add " ^ d
  | Quit -> " -> quit"

let entry = function
  | M.Separator -> print_endline "        ---"
  | Item i ->
      Printf.printf "        %s%s%s%s%s%s%s\n"
        (String.make (4 * i.indent) ' ')
        (match i.checked with
          | Some true -> "[x] "
          | Some false -> "[ ] "
          | None -> "")
        i.label
        (match i.icon with Some n -> " (" ^ n ^ ")" | None -> "")
        (if i.submenu then " >" else "")
        (if i.enabled then "" else " (disabled)")
        (action i.action)

let status text = M.status_of_json (Yojson.Safe.from_string text)

let menu ?(quit = "Quit tsync tray") domains =
  M.render ~quit (List.map (fun (name, reply) -> (name, status reply)) domains)

let show (m : M.t) =
  Printf.printf "icon    %s\ntooltip %s\n" m.icon m.tooltip;
  List.iter entry m.entries

let stats replies =
  List.iter entry
    (M.stats
       (List.filter_map
          (fun text -> M.stats_of_json (Yojson.Safe.from_string text))
          replies))

let silent = {|{"ok":false,"code":"internal","error":"no answer"}|}
let idle = {|{"ok":true}|}

let transfers n prefix =
  String.concat ","
    (List.init n (fun i ->
         Printf.sprintf {|{"name":"%s%d.bin","rel":"d/%s%d.bin"}|} prefix i
           prefix i))

let long_name =
  "Compte rendu de la réunion générale extraordinaire du comité élargi — \
   version définitive.PDF"

let () =
  case "formatters: bytes";
  List.iter
    (fun n -> Printf.printf "%d -> %s\n" n (Tsync_core.Narrate.size n))
    [
      0;
      999;
      1000;
      1500;
      999999;
      223200000;
      1070000000;
      12800000000;
      2500000000000;
    ];
  case "formatters: duration";
  List.iter
    (fun s ->
      Printf.printf "%g -> %s\n" s
        (Option.value ~default:"undefined" (M.duration s)))
    [0.; 45.; 60.; 90.; 3600.; 8000.; 86400.; 90000.; 180000.; -1.; nan; 1e13];
  case "formatters: time left";
  List.iter
    (fun (remaining, rate) ->
      Printf.printf "%g at %g/s -> %s\n" remaining rate
        (M.time_left ~remaining ~rate))
    [(100., 10.); (9000., 10.); (1., 1000.)];
  case "formatters: ellipsis";
  List.iter
    (fun s ->
      let cut = M.ellipsis s in
      Printf.printf "%d bytes -> %S (valid UTF-8: %b)\n" (String.length s) cut
        (String.is_valid_utf_8 cut))
    [
      "short.txt";
      String.make 64 'a';
      String.make 65 'a';
      String.make 63 'a' ^ "é" ^ "tail";
      String.make 40 'a' ^ " " ^ String.make 40 'b';
      String.make 10 'a' ^ " " ^ String.make 70 'b';
      long_name;
    ];
  case "formatters: file icon";
  List.iter
    (fun n -> Printf.printf "%s -> %s\n" n (M.file_icon n))
    [
      "a.JPG";
      "a.dng";
      "a.mkv";
      "a.opus";
      "a.csv";
      "a.odp";
      "a.epub";
      "a.tar.zst";
      "a.txt";
      "Makefile";
      ".pdf";
    ];

  case "the worked example of §5";
  show
    (menu
       [
         ( "photos",
           {|{"ok":true,"pendingUploads":1,"pendingDownloads":9,
              "uploading":[{"name":"out.raw","rel":"out.raw"}],
              "downloading":[
                {"name":"notes.pdf","rel":"notes.pdf","bytes":240000,"size":900000},
                {"name":"holiday.mov","rel":"trips/holiday.mov","bytes":788529152,
                 "size":15589124313,"rate":1600000}],
              "traffic":{"upBytes":1000},"pendingBytes":0}|}
         );
       ]);

  case "two domains, one busy: rows sorted, traffic and rate summed";
  show
    (menu
       [
         ( "photos",
           {|{"ok":true,"pendingUploads":2,
              "uploading":[{"name":"b.jpg","rel":"x/b.jpg","size":2048},
                           {"name":"a.jpg","rel":"x/a.jpg"}],
              "pendingBytes":1048576,"traffic":{"upBytes":5242880,"upRate":1048576}}|}
         );
         ( "music",
           {|{"ok":true,"pendingBytes":0,"traffic":{"upBytes":1048576,"upRate":0}}|}
         );
       ]);

  case "5 MiB at 1 MiB/s and 3 MiB at 2 MiB/s, pending bytes in each";
  show
    (menu
       [
         ( "one",
           {|{"ok":true,"pendingUploads":1,"pendingBytes":94371840,
              "traffic":{"upBytes":5242880,"upRate":1048576}}|}
         );
         ( "two",
           {|{"ok":true,"pendingUploads":1,"pendingBytes":94371840,
              "traffic":{"upBytes":3145728,"upRate":2097152}}|}
         );
       ]);

  case "nothing answering";
  show (menu [("photos", silent)]);

  case "one domain paused, one unreachable";
  show
    (menu
       [
         ("photos", {|{"ok":true,"paused":true,"pendingUploads":2}|});
         ("music", silent);
       ]);

  case "a machine joined one vault, while an upload runs";
  show
    (menu
       [
         ( "docs",
           {|{"ok":true,"pendingUploads":1,"uploading":[{"name":"a.txt","rel":"a.txt"}],
              "newMachines":["laptop",3,"booky"]}|}
         );
         ("music", idle);
       ]);

  case "one vault's scheduled backup is overdue";
  show
    (menu
       [
         ( "docs",
           {|{"ok":true,"newMachines":["laptop"],"vaultBackupOverdue":true}|} );
         ("music", idle);
       ]);

  case "one domain's sync failing with changes it cannot publish";
  show
    (menu
       [
         ( "media",
           {|{"ok":true,"pendingUploads":5,
              "failing":"5 changes cannot be published: this domain is read-only"}|}
         );
         ("music", {|{"ok":true,"pendingUploads":1}|});
       ]);

  case "two reachable domains, one paused";
  show (menu [("photos", {|{"ok":true,"paused":true}|}); ("music", idle)]);

  case "paused with more uploads than FILE_ROWS, rate zero";
  show
    (menu
       [
         ( "photos",
           Printf.sprintf
             {|{"ok":true,"paused":true,"pendingUploads":9,"uploading":[%s],
                "pendingBytes":7000000,"traffic":{"upBytes":0,"upRate":0}}|}
             (transfers 7 "u") );
       ]);

  case "a fetch count of nine above two download rows";
  show
    (menu
       [
         ( "photos",
           Printf.sprintf
             {|{"ok":true,"pendingDownloads":9,"downloading":[%s]}|}
             (transfers 2 "d") );
       ]);
  case "a fetch count of zero above one download row";
  show
    (menu
       [
         ( "photos",
           Printf.sprintf
             {|{"ok":true,"pendingDownloads":0,"downloading":[%s]}|}
             (transfers 1 "d") );
       ]);
  case "a fetch count with no row";
  show (menu [("photos", {|{"ok":true,"pendingDownloads":3}|})]);

  case "more downloads than fit beside uploads";
  show
    (menu
       [
         ( "photos",
           Printf.sprintf
             {|{"ok":true,"pendingUploads":6,"uploading":[%s],"downloading":[%s]}|}
             (transfers 6 "u") (transfers 8 "d") );
       ]);

  case "figures absent";
  show
    (menu
       [
         ( "photos",
           {|{"ok":true,"downloading":[{"name":"a.bin","rel":"a.bin"}]}|} );
       ]);
  case "figures zero";
  show
    (menu
       [
         ( "photos",
           {|{"ok":true,"downloading":[{"name":"a.bin","rel":"a.bin","bytes":0,"size":0,"rate":0}],
              "pendingBytes":0,"traffic":{"upBytes":0,"upRate":0}}|}
         );
       ]);

  case "a name longer than LABEL_MAX with a known extension";
  show
    (menu
       [
         ( "docs",
           Yojson.Safe.to_string
             (`Assoc
                [
                  ("ok", `Bool true);
                  ( "downloading",
                    `List
                      [
                        `Assoc
                          [
                            ("name", `String long_name);
                            ("rel", `String ("cr/" ^ long_name));
                          ];
                      ] );
                ]) );
       ]);

  case "no domains, with a quit label";
  show (menu []);
  case "no domains, without a quit label";
  show (M.render []);
  case "one idle domain, without a quit label";
  show (M.render [("photos", status idle)]);

  case "the JSON form: every kind of entry and action";
  let m =
    menu
      [
        ( "photos",
          {|{"ok":true,"paused":true,"pendingUploads":1,
             "downloading":[{"name":"a.mkv","rel":"v/a.mkv","size":1153434}],
             "traffic":{"upBytes":10},"pendingBytes":0}|}
        );
      ]
  in
  print_endline (Yojson.Safe.pretty_to_string (M.to_json m));
  print_endline
    (Yojson.Safe.to_string
       (`List (List.map M.entry_to_json M.stats_placeholder)));

  case "stats: before any answer";
  List.iter entry M.stats_placeholder;
  case "stats: nothing answering";
  stats [silent];
  case "stats: full, two processes";
  stats
    [
      {|{"ok":true,
         "self":{"server":{"hostname":"box","role":"owner","pid":102259,"uptimeSeconds":43500},
                 "process":{"cpuPercentAvg":1.0,"rssBytes":775788953,"heapBytes":88394957},
                 "traffic":{"upBytes":0,"upRate":0,"downBytes":12455405158,"downRate":1572864}},
         "domains":[{"name":"Media",
           "settings":{"readOnly":true,"versioning":true,"extensions":["totp"]},
           "cache":{"chunks":1216,"bytes":10737418240,"maxCache":10737418240,"pinnedBytes":2147483648},
           "queues":{"pendingFiles":0,"bytesOwed":0,"parked":1},
           "sync":{"position":402,"pending":3,"treeHead":402},
           "extensions":[],"frontends":[{"type":"fuse","mount":"/home/u/tsync/Media","bytesRead":540436070,"bytesWritten":0},
                        {"type":"http-proxy","bytesRead":10,"bytesWritten":5}],
           "backends":[
             {"name":"http-proxy","role":"main","reach":{"reachable":true,"latencyMs":11.4},
              "corrupted":{"checked":true,"chunks":0}},
             {"name":"cold","role":"replica","reach":{"reachable":false,"error":"connection refused"},
              "corrupted":{"checked":true,"chunks":3}},
             {"name":"far","role":"backfill","reach":{"reachable":false,"error":""},
              "corrupted":{"checked":false,"reason":"never"}}]}]}|};
      {|{"ok":true,
         "self":{"server":{"hostname":"box","role":"owner","pid":7,"uptimeSeconds":12}},
         "domains":[{"name":"Files","settings":{"readOnly":false,"versioning":false}},
                    {"name":"Gone","unanswered":true}]}|};
    ];
  case "stats: sparse";
  stats [{|{"ok":true,"self":{"server":{"hostname":"box"}}}|}];
  case "stats: an entry that cannot be followed";
  stats
    [
      {|{"ok":true,"domains":[{"name":"Files",
         "sync":{"position":7,"pending":0,
                 "cannotFollow":{"entry":8,"reason":"it is of version 2"}},
         "backends":[{"name":"gcs","role":"main","reach":{"reachable":true}}]}]}|};
    ];

  let codes ?add answers =
    List.iter entry
      (M.codes ?add
         (List.map
            (fun (d, reply) ->
              (d, M.codes_of_json (Option.map Yojson.Safe.from_string reply)))
            answers))
  in
  let two_records =
    {|{"ok":true,"records":[
       {"id":"3f2a","issuer":"ACME Co","account":"john@example.com","code":"123456","secondsLeft":9},
       {"id":"9c1e","issuer":"GitHub","account":"","code":"654321","secondsLeft":9},
       {"id":"77aa","issuer":"","account":"bob","code":"000000","secondsLeft":9}],"corrupt":[]}|}
  in
  case "codes: a menu with code domains has the row, one without has not";
  show
    (M.render ~quit:"Quit tsync tray" ~codes:["work"] [("work", status idle)]);
  case "codes: before any answer";
  List.iter entry M.codes_placeholder;
  case "codes: one domain";
  codes [("work", Some two_records)];
  case "codes: two domains, one locked";
  codes
    [
      ("work", Some two_records);
      ( "home",
        Some {|{"ok":false,"code":"locked","error":"the vault is locked"}|} );
    ];
  case "codes: no vault, not answering, no codes, unreadable records";
  codes
    [
      ("a", Some {|{"ok":false,"code":"not_found","error":"no vault"}|});
      ("b", None);
      ("c", Some {|{"ok":false,"code":"internal","error":"boom"}|});
      ("d", Some {|{"ok":true,"records":[],"corrupt":[]}|});
      ("e", Some {|{"ok":true,"records":[],"corrupt":["x","y"]}|});
      ( "f",
        Some
          (Printf.sprintf
             {|{"ok":true,"records":[{"id":"1","issuer":"%s","account":"me"}],"corrupt":["z"]}|}
             (String.make 80 'L')) );
    ];
  case "codes: no code domain at all";
  codes [];
  case "codes: a caller that adds no codes gets no Add a code row";
  codes ~add:false
    [
      ("work", Some two_records);
      ("d", Some {|{"ok":true,"records":[],"corrupt":[]}|});
    ];
  case "codes: the JSON form, and no code in any row";
  let rows =
    M.codes
      [
        ("work", M.codes_of_json (Some (Yojson.Safe.from_string two_records)));
        ( "home",
          M.codes_of_json
            (Some (Yojson.Safe.from_string {|{"ok":false,"code":"locked"}|})) );
      ]
  in
  let json = Yojson.Safe.to_string (`List (List.map M.entry_to_json rows)) in
  print_endline json;
  Printf.printf "the reply carries 123456: %b\n"
    (Tsync_core.Text.contains two_records "123456");
  List.iter
    (fun code ->
      Printf.printf "carries %s: %b\n" code (Tsync_core.Text.contains json code))
    ["123456"; "654321"; "000000"];

  case "replies with fields of the wrong type, and an empty object";
  show
    (menu
       [
         ("empty", "{}");
         ("list", "[]");
         ( "wrong",
           {|{"ok":true,"pendingUploads":"3","pendingDownloads":2.5,"paused":"yes",
              "uploading":{"name":"x"},"downloading":[3,{"name":"","rel":"a"},{"name":"a"},
                {"name":"ok.txt","rel":"ok.txt","bytes":"12","size":[],"rate":null}],
              "pendingBytes":true,"traffic":[1,2]}|}
         );
       ]);
  stats
    [
      "{}";
      {|{"ok":true,"self":[],"domains":{"name":"x"}}|};
      {|{"ok":true,"self":{"server":"box","process":3,"traffic":null},
         "domains":[7,{"name":3},{"name":"d","settings":1,"cache":{"chunks":"many"},
           "queues":[],"sync":{"pending":"1","cannotFollow":3},"frontends":[1,{"mount":4}],
           "backends":[{"reach":"up","corrupted":"no"}]}]}|};
    ];

  if !cases = 0 then failwith "no case ran";
  Printf.printf "\n%d cases\n" !cases
