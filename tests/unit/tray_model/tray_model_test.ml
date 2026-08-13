(* The tray menu is a copy of the one in macos/TsyncApp/StatusMenu.swift, and a
   copy is only worth having if it stays one. This prints what the model would
   draw, so a change to any of those strings has to be agreed to in the diff.

   It runs on both platforms deliberately: the macOS runner is where a
   divergence from the menu being copied would actually be noticed. *)

let action = function
  | Tray_model.Nothing -> ""
  | Open_folder p -> " -> open " ^ p
  | Reveal_file p -> " -> reveal " ^ p
  | Set_paused b -> Printf.sprintf " -> pause %b" b
  (* A submenu: the row opens one rather than doing anything, which the trailing
     marker below already says. *)
  | Show_stats -> ""
  | Quit -> " -> quit"

let print_entries entries =
  List.iter
    (function
      | Tray_model.Separator -> print_endline "        ---"
      | Item i ->
          Printf.printf "        %s%s%s%s%s%s\n"
            (String.make (4 * i.Tray_model.indent) ' ')
            (match i.Tray_model.checked with
              | Some true -> "[x] "
              | Some false -> "[ ] "
              | None -> "")
            i.Tray_model.label
            (match i.Tray_model.icon with
              | Some c -> " (" ^ c ^ ")"
              | None -> "")
            (if i.Tray_model.submenu then " >" else "")
            (if i.Tray_model.enabled then action i.Tray_model.action
             else " (disabled)"))
    entries

let print_menu name statuses =
  let m = Tray_model.render statuses in
  Printf.printf "== %s\n" name;
  Printf.printf "icon    %s\n" m.Tray_model.icon;
  Printf.printf "tooltip %s\n" m.Tray_model.tooltip;
  print_entries m.Tray_model.entries;
  print_newline ()

let print_stats name all =
  Printf.printf "== %s\n" name;
  print_entries (Tray_model.stats_entries all);
  print_newline ()

let upload name rel = { Tray_model.name; rel }

let domain ?(uploads = 0) ?(downloads = 0) ?(paused = false) ?(uploading = [])
    ?(pending = 0L) ?sent ?rate ?mount name =
  {
    Tray_model.name;
    uploads = Some uploads;
    downloads = Some downloads;
    paused = Some paused;
    uploading;
    pending_bytes = Some pending;
    bytes_uploaded = sent;
    upload_rate = rate;
    mount;
  }

let () =
  (* Two domains, one busy. Pins the sort order (a_1.jpg before b.mov), that
     bytesUploaded is read once rather than summed over the two domains, and
     the two formatters. *)
  print_menu "two domains, one busy"
    [
      domain "photos" ~uploads:3 ~mount:"/home/u/tsync/photos"
        ~uploading:[upload "b.mov" "b.mov"; upload "a_1.jpg" "a_1.jpg"]
        ~pending:12_800_000_000L ~sent:223_200_000L ~rate:1_600_000.;
      domain "docs" ~mount:"/home/u/tsync/docs" ~sent:223_200_000L
        ~rate:1_600_000.;
    ];

  (* Nothing answering. No traffic or rate line at all -- the daemon never told
     us a total, and inventing one is worse than leaving it out. *)
  print_menu "daemon not running"
    [
      {
        (Tray_model.unreachable "photos") with
        mount = Some "/home/u/tsync/photos";
      };
    ];

  (* Paused with a backlog: the overflow row, and no rate line because the rate
     is zero. *)
  print_menu "paused with a backlog"
    [
      domain "photos" ~paused:true ~mount:"/home/u/tsync/photos" ~pending:500L
        ~sent:0L ~rate:0.
        ~uploading:
          (List.map
             (fun n ->
               upload (Printf.sprintf "f%d.txt" n) (Printf.sprintf "f%d.txt" n))
             [7; 1; 2; 3; 4; 5; 6]);
    ];

  (* A domain that answers but has no mount to open, alongside one that does:
     the row is still worth showing, it just cannot go anywhere. *)
  print_menu "one domain not mounted"
    [domain "photos" ~downloads:2 ~sent:1_070_000_000L];

  print_menu "no domains" [];

  (* The submenu, which is the part of the report that does not fit in the menu.
     Pins that cpuPercentAvg is printed as it arrives rather than scaled, that a
     rate of zero is left off, that a backend which is behind says so while one
     that is not stays quiet, and that a wal with nothing owed draws no row. *)
  let backend ?latency ?error ?behind ~reachable name role entries =
    {
      Tray_model.backend_name = name;
      role;
      backend_reachable = reachable;
      latency_ms = latency;
      backend_error = error;
      journal_entries = entries;
      journal_behind = behind;
    }
  in
  print_stats "stats submenu"
    [
      {
        Tray_model.host = "booky";
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
              Tray_model.domain_name = "Jellyfin Media";
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
        Tray_model.host = "server";
        frontend = "headless";
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
              Tray_model.domain_name = "docs";
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
              backends = [backend "disk" "main" ~reachable:true ~behind:0 None];
            };
          ];
      };
    ];

  print_stats "stats, nothing answering" [];

  print_endline "== human_bytes";
  List.iter
    (fun n -> Printf.printf "%-16Ld %s\n" n (Tray_model.human_bytes n))
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
        (match Tray_model.eta s with Some t -> t | None -> "(none)"))
    [0.; 45.; 60.; 90.; 3600.; 8000.; 86_400.; 90_000.; 180_000.];

  print_newline ();
  print_endline "== file_icon";
  List.iter
    (fun n -> Printf.printf "%-16s %s\n" n (Tray_model.file_icon n))
    ["a.jpg"; "b.MOV"; "c.flac"; "d.pdf"; "e.xlsx"; "f.zip"; "g.txt"; "h"]
