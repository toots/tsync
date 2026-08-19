(* Every string the tray draws, printed. The menu is what a user reads to decide
   whether anything is wrong, so a change to any of it has to be agreed to in the
   diff rather than noticed on a desktop.

   Builds on both platforms, since the model links no D-Bus and no toolkit. *)

let action = function
  | Menu.Nothing -> ""
  | Open_folder p -> " -> open " ^ p
  | Reveal_file { Menu.domain; rel } ->
      Printf.sprintf " -> reveal %s:%s" domain rel
  | Set_paused b -> Printf.sprintf " -> pause %b" b
  (* A submenu: the row opens one rather than doing anything, which the trailing
     marker below already says. *)
  | Show_stats -> ""
  | Quit -> " -> quit"

let print_entries entries =
  List.iter
    (function
      | Menu.Separator -> print_endline "        ---"
      | Item i ->
          Printf.printf "        %s%s%s%s%s%s\n"
            (String.make (4 * i.Menu.indent) ' ')
            (match i.Menu.checked with
              | Some true -> "[x] "
              | Some false -> "[ ] "
              | None -> "")
            i.Menu.label
            (match i.Menu.icon with Some c -> " (" ^ c ^ ")" | None -> "")
            (if i.Menu.submenu then " >" else "")
            (if i.Menu.enabled then action i.Menu.action else " (disabled)"))
    entries

let print_menu name statuses =
  let m = Menu.render statuses in
  Printf.printf "== %s\n" name;
  Printf.printf "icon    %s\n" m.Menu.icon;
  Printf.printf "tooltip %s\n" m.Menu.tooltip;
  print_entries m.Menu.entries;
  print_newline ()

let print_stats name all =
  Printf.printf "== %s\n" name;
  print_entries (Menu.stats_entries all);
  print_newline ()

let upload ?moved ?total ?rate name rel = { Menu.name; rel; moved; total; rate }

let domain ?(uploads = 0) ?(downloads = 0) ?(paused = false) ?(uploading = [])
    ?(downloading = []) ?(pending = 0L) ?sent ?rate name =
  {
    Menu.name;
    uploads = Some uploads;
    downloads = Some downloads;
    paused = Some paused;
    uploading;
    downloading;
    pending_bytes = Some pending;
    bytes_uploaded = sent;
    upload_rate = rate;
  }

let () =
  (* Two domains, one busy. Pins the sort order (a_1.jpg before b.mov), that
     bytesUploaded is read once rather than summed over the two domains, and
     the two formatters. *)
  print_menu "two domains, one busy"
    [
      domain "photos" ~uploads:3
        ~uploading:[upload "b.mov" "b.mov"; upload "a_1.jpg" "a_1.jpg"]
        ~pending:12_800_000_000L ~sent:223_200_000L ~rate:1_600_000.;
      domain "docs" ~sent:223_200_000L ~rate:1_600_000.;
    ];

  (* Nothing answering. No traffic or rate line at all -- the daemon never told
     us a total, and inventing one is worse than leaving it out. *)
  print_menu "daemon not running" [Menu.unreachable "photos"];

  (* Paused with a backlog: the overflow row, and no rate line because the rate
     is zero. *)
  print_menu "paused with a backlog"
    [
      domain "photos" ~paused:true ~pending:500L ~sent:0L ~rate:0.
        ~uploading:
          (List.map
             (fun n ->
               upload (Printf.sprintf "f%d.txt" n) (Printf.sprintf "f%d.txt" n))
             [7; 1; 2; 3; 4; 5; 6]);
    ];

  (* Downloads counted but no rows to show for them: the daemon left them out as
     too small, and the count still comes from somewhere. *)
  print_menu "downloads below the threshold"
    [domain "photos" ~downloads:2 ~sent:1_070_000_000L];

  (* Downloads draw exactly as uploads do, and the count on the domain row is
     the number of rows under it -- not pendingDownloads, which counts chunk
     fetches and would read "Downloading 9" above two files. *)
  print_menu "downloading, with uploads alongside"
    [
      domain "photos" ~uploads:1 ~downloads:9
        ~uploading:[upload "out.raw" "out.raw"]
        ~downloading:
          [
            upload "holiday.mov" "trips/holiday.mov" ~moved:788_529_152L
              ~total:15_589_124_313L ~rate:1_600_000.;
            (* Reported without a rate yet, so no estimate is offered. *)
            upload "notes.pdf" "notes.pdf" ~moved:240_000L ~total:900_000L;
          ]
        ~sent:1_000L;
    ];

  (* The overflow row belongs to each list on its own. *)
  print_menu "more downloads than fit"
    [
      domain "photos" ~downloads:7
        ~downloading:
          (List.map
             (fun n ->
               upload (Printf.sprintf "f%d.iso" n) (Printf.sprintf "f%d.iso" n))
             [7; 1; 2; 3; 4; 5; 6])
        ~sent:0L;
    ];

  print_menu "no domains" [];

  (* The wire the macOS menu draws from. Pinned because nothing on this side can
     compile the client that reads it: a field renamed here is a menu that comes
     up empty over there, and this is what would say so. *)
  print_endline "== menu as JSON";
  print_endline
    (Yojson.Safe.pretty_to_string
       (Menu.to_json
          (Menu.render ~quit_label:"Quit tsync menu bar"
             [
               domain "photos" ~uploads:1
                 ~uploading:[upload "out.raw" "out.raw" ~total:1_200_000L]
                 ~downloading:
                   [
                     upload "holiday.mov" "trips/holiday.mov"
                       ~moved:788_529_152L ~total:15_589_124_313L
                       ~rate:1_600_000.;
                   ]
                 ~sent:1_000L;
             ])));
  print_newline ();

  (* The submenu, which is the part of the report that does not fit in the menu.
     Pins that cpuPercentAvg is printed as it arrives rather than scaled, that a
     rate of zero is left off, that a backend which is behind says so while one
     that is not stays quiet, and that a wal with nothing owed draws no row. *)
  let backend ?latency ?error ?behind ?corrupted ?(corruption = `Checked)
      ~reachable name role entries =
    {
      Menu.backend_name = name;
      role;
      backend_reachable = reachable;
      latency_ms = latency;
      backend_error = error;
      journal_entries = entries;
      journal_behind = behind;
      corrupted_chunks = corrupted;
      corruption;
    }
  in
  print_stats "stats submenu"
    [
      {
        Menu.host = "booky";
        frontend = "fuse";
        pid = 102259;
        uptime = 43_511.;
        cpu_percent = 0.976;
        rss = 775_733_248L;
        heap = 88_342_648L;
        uploaded = 0L;
        up_rate = 0.;
        downloaded = 12_485_155_770L;
        down_rate = 1_600_000.;
        domain_stats =
          [
            {
              Menu.domain_name = "Jellyfin Media";
              mount_point = Some "/home/u/tsync/Jellyfin Media";
              read_only = true;
              versioning = true;
              cache_chunks = Some 1216;
              cache_bytes = Some 10_734_340_306L;
              cache_max = Some 10_737_418_240L;
              in_uploads = Some 0;
              in_downloads = Some 2;
              staged = Some 0;
              bytes_read = Some 540_405_961L;
              bytes_written = Some 0L;
              wal_pending = Some 0;
              wal_stuck = Some 0;
              backends =
                [
                  backend "http-proxy" "main" ~reachable:true ~latency:10.57
                    ~behind:0 (Some 402);
                  backend "cold" "replica" ~reachable:false
                    ~error:"connection refused" ~behind:12 (Some 88);
                ];
            };
          ];
      };
    ];

  (* A domain whose frontend keeps none of those counters, and a backlog that
     does: every row that has nothing behind it is left out rather than drawn as
     a zero. *)
  print_stats "stats, sparse"
    [
      {
        Menu.host = "server";
        frontend = "android";
        pid = 7;
        uptime = 12.;
        cpu_percent = 0.;
        rss = 41_200_000L;
        heap = 8_000_000L;
        uploaded = 223_200_000L;
        up_rate = 1_600_000.;
        downloaded = 0L;
        down_rate = 0.;
        domain_stats =
          [
            {
              Menu.domain_name = "docs";
              mount_point = None;
              read_only = false;
              versioning = false;
              cache_chunks = None;
              cache_bytes = None;
              cache_max = None;
              in_uploads = None;
              in_downloads = None;
              staged = None;
              bytes_read = None;
              bytes_written = None;
              wal_pending = Some 3;
              wal_stuck = Some 1;
              backends =
                [
                  backend "disk" "main" ~reachable:true ~behind:0 None;
                  (* A checked store with damage says so and says what to run;
                     a store nothing checks says that instead, because its zero
                     means something else entirely. *)
                  backend "cloud" "replica" ~reachable:true ~behind:0
                    ~corrupted:3 None;
                  backend "archive" "readOnly" ~reachable:true ~behind:0
                    ~corruption:`Unchecked None;
                  (* A probe that failed has said nothing about this store's
                     bytes, which is not the same as nothing checking it. *)
                  backend "flaky" "replica" ~reachable:true ~behind:0
                    ~corruption:`Failed None;
                ];
            };
          ];
      };
    ];

  print_stats "stats, nothing answering" [];

  print_endline "== human_bytes";
  List.iter
    (fun n -> Printf.printf "%-16Ld %s\n" n (Menu.human_bytes n))
    [
      0L;
      1L;
      999L;
      1_000L;
      1_500L;
      999_999L;
      1_000_000L;
      223_200_000L;
      1_000_000_000L;
      1_070_000_000L;
      12_800_000_000L;
      5_000_000_000L;
      2_500_000_000_000L;
    ];

  print_newline ();
  print_endline "== eta";
  List.iter
    (fun s ->
      Printf.printf "%-10.0f %s\n" s
        (match Menu.eta s with Some t -> t | None -> "(none)"))
    [0.; 45.; 60.; 90.; 3600.; 8000.; 86_400.; 90_000.; 180_000.];

  print_newline ();
  print_endline "== file_icon";
  List.iter
    (fun n -> Printf.printf "%-16s %s\n" n (Menu.file_icon n))
    ["a.jpg"; "b.MOV"; "c.flac"; "d.pdf"; "e.xlsx"; "f.zip"; "g.txt"; "h"]
