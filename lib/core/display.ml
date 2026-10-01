type mode = Quiet | Normal | Verbose

let mode = Atomic.make Normal
let m = Mutex.create ()
let tty = lazy (Unix.isatty Unix.stderr)
let text = ref None
let fraction = ref None
let started = ref None
let drawn = ref false
let last_plain = ref 0.
let ticker = ref false
let spinner = [| "|"; "/"; "-"; "\\" |]
let tick = ref 0
let plain_every = 10.

let stamp () =
  let tm = Unix.localtime (Unix.gettimeofday ()) in
  Printf.sprintf "%02d:%02d:%02d" tm.tm_hour tm.tm_min tm.tm_sec

(* Code points, so a cut never splits a character. *)
let truncate width s =
  let rec cut i cps =
    if i >= String.length s then s
    else if cps = width - 1 then String.sub s 0 i ^ "…"
    else (
      let n = Uchar.utf_decode_length (String.get_utf_8_uchar s i) in
      cut (i + n) (cps + 1))
  in
  if width <= 1 then "" else cut 0 0

let bar f =
  let f = Float.min 1. (Float.max 0. f) in
  let filled = int_of_float (f *. 20.) in
  Printf.sprintf "[%s%s] %3.0f%% " (String.make filled '#')
    (String.make (20 - filled) '-')
    (f *. 100.)

(* The functions below run under [m]. *)
let erase () =
  if !drawn then (
    prerr_string "\r\027[K";
    drawn := false)

let draw () =
  match (!text, !started) with
    | Some s, Some t0 when Lazy.force tty ->
        let width =
          Option.value ~default:80 (Fs.terminal_columns Unix.stderr)
        in
        incr tick;
        let line =
          Printf.sprintf "%s %s%s  %s"
            spinner.(!tick mod Array.length spinner)
            (Option.fold ~none:"" ~some:bar !fraction)
            s
            (Narrate.duration (Unix.gettimeofday () -. t0))
        in
        prerr_string ("\r\027[K" ^ truncate width line);
        flush stderr;
        drawn := true
    | _ -> ()

let around f =
  Mutex.protect m (fun () ->
      erase ();
      f ();
      draw ();
      flush stderr)

let start_ticker () =
  if not !ticker then (
    ticker := true;
    ignore
      (Thread.create
         (fun () ->
           while true do
             Thread.delay 0.25;
             Mutex.protect m draw
           done)
         ()))

let progress ?fraction:f s =
  if Atomic.get mode <> Quiet then
    Mutex.protect m (fun () ->
        if !started = None then (
          started := Some (Unix.gettimeofday ());
          last_plain := Unix.gettimeofday ());
        text := Some s;
        fraction := f;
        if Lazy.force tty then start_ticker ()
        else (
          let now = Unix.gettimeofday () in
          if now -. !last_plain >= plain_every then (
            last_plain := now;
            prerr_endline
              (Printf.sprintf "%s %s%s" (stamp ()) s
                 (Option.fold ~none:""
                    ~some:(fun f -> Printf.sprintf " (%.0f%%)" (f *. 100.))
                    f)))))

let say s =
  if Atomic.get mode = Verbose then
    around (fun () -> prerr_endline (stamp () ^ " " ^ s))

let narrate () = { Narrate.say; progress }

(* A result line ends the step being shown; the next progress starts anew. *)
let out s =
  Mutex.protect m (fun () ->
      erase ();
      text := None;
      flush stderr;
      print_endline s;
      flush stdout)

let clear () =
  Mutex.protect m (fun () ->
      erase ();
      text := None;
      flush stderr)

let configure ~verbose ~quiet =
  Atomic.set mode (if quiet then Quiet else if verbose then Verbose else Normal);
  let log = Atomic.get Log.sink in
  Atomic.set Log.sink (fun level msg -> around (fun () -> log level msg));
  at_exit clear
