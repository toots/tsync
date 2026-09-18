(* Every line an export in flight can show. Nothing in here reads a clock, so
   the rates and what they make of the time left are the ones written below. *)

let gb n = Int64.mul (Int64.of_int n) 1_000_000_000L
let mb n = Int64.mul (Int64.of_int n) 1_000_000L

let show label state =
  print_endline label;
  List.iter
    (fun line -> print_endline ("  " ^ line))
    (Export_display.render state)

let file ?(rate = 0.) name ~moved ~total =
  { Export_display.name; moved; total; rate }

let () =
  show "one file, which is its own total"
    {
      Export_display.files = 1;
      finished = 0;
      moved = gb 12;
      total = gb 51;
      rate = 118e6;
      active =
        [
          file "01_FOOTAGE/01_CAM 1/P1016637.MOV" ~moved:(gb 12) ~total:(gb 51)
            ~rate:118e6;
        ];
    };
  show "several at once, named in order under a line for the run"
    {
      Export_display.files = 40;
      finished = 12;
      moved = gb 30;
      total = gb 140;
      rate = 96e6;
      active =
        [
          file "b/ZOOM0008_Tr1.WAV" ~moved:(mb 300) ~total:(mb 611) ~rate:40e6;
          file "a/P1016638.MOV" ~moved:(gb 2) ~total:(gb 18) ~rate:56e6;
        ];
    };
  show "nothing moving"
    {
      Export_display.files = 2;
      finished = 0;
      moved = gb 1;
      total = gb 4;
      rate = 0.;
      active = [file "stalled.bin" ~moved:(gb 1) ~total:(gb 4)];
    };
  show "less than a minute to go"
    {
      Export_display.files = 1;
      finished = 0;
      moved = mb 990;
      total = gb 1;
      rate = 10e6;
      active = [file "nearly.bin" ~moved:(mb 990) ~total:(gb 1) ~rate:10e6];
    };
  show "between files, with none open"
    {
      Export_display.files = 3;
      finished = 3;
      moved = gb 4;
      total = gb 4;
      rate = 0.;
      active = [];
    };
  show "before anything is known, which is nothing to draw"
    {
      Export_display.files = 0;
      finished = 0;
      moved = 0L;
      total = 0L;
      rate = 0.;
      active = [];
    };
  print_endline "a line wider than the terminal";
  List.iter
    (fun width ->
      Printf.printf "  %2d |%s|\n" width
        (Common.fit ~width "Événement spécial · 12 GB of 51 GB"))
    [80; 20; 10; 1]

(* What reaches a terminal, byte for byte: stderr is a file here and the display
   is told somebody is watching, so the escapes it would send are what is read
   back. The log shares that terminal, and has to find the line clear. *)
let () =
  let path = Filename.temp_file "tsync-live" ".raw" in
  let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
  let saved = Unix.dup Unix.stderr in
  Unix.putenv "COLUMNS" "60";
  flush stderr;
  Unix.dup2 fd Unix.stderr;
  let live = Common.live_output ~watching:true () in
  live.Common.block ["one.bin · 1 MB of 9 MB"; "0 of 2 files · 1 MB of 9 MB"];
  live.Common.block ["one.bin · 2 MB of 9 MB"; "0 of 2 files · 2 MB of 9 MB"];
  Tsync_core.Log.set_min_level `info;
  Tsync_core.Log.info "gcs get: Lwt_unix.Timeout; retrying (1/8) in 0.5s";
  live.Common.block ["one.bin · 3 MB of 9 MB"; "0 of 2 files · 3 MB of 9 MB"];
  live.Common.note "a line that stays";
  live.Common.block ["two.bin · 1 MB of 2 MB"];
  live.Common.clear ();
  flush stderr;
  Unix.dup2 saved Unix.stderr;
  Unix.close fd;
  let ic = open_in_bin path in
  let raw = really_input_string ic (in_channel_length ic) in
  close_in ic;
  Sys.remove path;
  let stamp = Str.regexp "20[0-9-]+ [0-9:]+" in
  let shown =
    Str.global_replace stamp "<time>" raw
    |> Str.global_replace (Str.regexp_string "\027[J") "<clear>"
    |> Str.global_replace (Str.regexp "\027\\[\\([0-9]+\\)A") "<up \\1>"
    |> Str.global_replace (Str.regexp_string "\r") "<cr>"
  in
  print_endline "what a terminal is sent";
  List.iter
    (fun line -> print_endline ("  " ^ line))
    (String.split_on_char '\n' shown)
