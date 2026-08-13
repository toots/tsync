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
  | Quit -> " -> quit"

let print_menu name statuses =
  let m = Tray_model.render statuses in
  Printf.printf "== %s\n" name;
  Printf.printf "icon    %s\n" m.Tray_model.icon;
  Printf.printf "tooltip %s\n" m.Tray_model.tooltip;
  List.iter
    (function
      | Tray_model.Separator -> print_endline "        ---"
      | Item i ->
          Printf.printf "        %s%s%s%s%s\n"
            (String.make (4 * i.Tray_model.indent) ' ')
            (match i.Tray_model.checked with
              | Some true -> "[x] "
              | Some false -> "[ ] "
              | None -> "")
            i.Tray_model.label
            (match i.Tray_model.icon with Some c -> " (" ^ c ^ ")" | None -> "")
            (if i.Tray_model.enabled then action i.Tray_model.action
             else " (disabled)"))
    m.Tray_model.entries;
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
      domain "docs" ~mount:"/home/u/tsync/docs" ~sent:223_200_000L ~rate:1_600_000.;
    ];

  (* Nothing answering. No traffic or rate line at all -- the daemon never told
     us a total, and inventing one is worse than leaving it out. *)
  print_menu "daemon not running"
    [{ (Tray_model.unreachable "photos") with mount = Some "/home/u/tsync/photos" }];

  (* Paused with a backlog: the overflow row, and no rate line because the rate
     is zero. *)
  print_menu "paused with a backlog"
    [
      domain "photos" ~paused:true ~mount:"/home/u/tsync/photos" ~pending:500L
        ~sent:0L ~rate:0.
        ~uploading:
          (List.map
             (fun n -> upload (Printf.sprintf "f%d.txt" n) (Printf.sprintf "f%d.txt" n))
             [7; 1; 2; 3; 4; 5; 6]);
    ];

  (* A domain that answers but has no mount to open, alongside one that does:
     the row is still worth showing, it just cannot go anywhere. *)
  print_menu "one domain not mounted"
    [domain "photos" ~downloads:2 ~sent:1_070_000_000L];

  print_menu "no domains" [];

  print_endline "== human_bytes";
  List.iter
    (fun n -> Printf.printf "%-16Ld %s\n" n (Tray_model.human_bytes n))
    [
      0L; 1L; 999L; 1_000L; 1_500L; 999_999L; 1_000_000L; 223_200_000L;
      1_000_000_000L; 1_070_000_000L; 12_800_000_000L; 5_000_000_000L;
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
