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
  | Show_stats -> ""
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
           "settings":{"readOnly":true,"versioning":true},
           "cache":{"chunks":1216,"bytes":10737418240,"maxCache":10737418240,"pinnedBytes":2147483648},
           "queues":{"pendingFiles":0,"bytesOwed":0},
           "wal":{"intent":1,"prepared":2,"executed":0,"stuck":1},
           "frontends":[{"type":"fuse","mount":"/home/u/tsync/Media","bytesRead":540436070,"bytesWritten":0},
                        {"type":"http-proxy","bytesRead":10,"bytesWritten":5}],
           "backends":[
             {"name":"http-proxy","role":"main","reach":{"reachable":true,"latencyMs":11.4},
              "journal":{"entries":402,"behind":0},"corrupted":{"checked":true,"chunks":0}},
             {"name":"cold","role":"replica","reach":{"reachable":false,"error":"connection refused"},
              "journal":{"entries":88,"behind":12},"corrupted":{"checked":true,"chunks":3}},
             {"name":"far","role":"backfill","reach":{"reachable":false,"error":""},
              "journal":{"error":"denied"},"corrupted":{"checked":false,"reason":"never"}}]}]}|};
      {|{"ok":true,
         "self":{"server":{"hostname":"box","role":"owner","pid":7,"uptimeSeconds":12}},
         "domains":[{"name":"Files","settings":{"readOnly":false,"versioning":false}},
                    {"name":"Gone","unanswered":true}]}|};
    ];
  case "stats: sparse";
  stats [{|{"ok":true,"self":{"server":{"hostname":"box"}}}|}];
  case "stats: a journal still counting";
  stats
    [
      {|{"ok":true,"domains":[{"name":"Files",
         "backends":[{"name":"gcs","role":"main","reach":{"reachable":true},
                      "journal":{"counting":true}}]}]}|};
    ];

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
           "queues":[],"wal":{"stuck":"1"},"frontends":[1,{"mount":4}],
           "backends":[{"reach":"up","journal":3,"corrupted":"no"}]}]}|};
    ];

  if !cases = 0 then failwith "no case ran";
  Printf.printf "\n%d cases\n" !cases
