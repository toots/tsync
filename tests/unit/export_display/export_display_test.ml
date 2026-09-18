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
  print_endline "a line wider than the terminal";
  List.iter
    (fun width ->
      Printf.printf "  %2d |%s|\n" width
        (Common.fit ~width "Événement spécial · 12 GB of 51 GB"))
    [80; 20; 10; 1]
