(* What a sweep of the record directory reads, what it deletes, and what it
   says.

   The first two are asked with a deliberately corrupt record, because it is the
   one whose fate says whether its body was opened at all: a sweep that reads it
   discards it, and a sweep that skipped it on its id alone leaves it where it
   was.

   The rest are the three ways a read can end, which have three different right
   answers: a job, a record another worker completed first, and a record that
   would not open at all. Only the middle of those is silent and only the
   corrupt one may be dropped.

   Nothing here reads a clock, and log lines are printed without their
   timestamps, so the output is the same on any machine. *)

open Lwt.Syntax

let root = Scratch.dir "queue-records"

module Q = Durable_queue_lwt.Make (struct
  type t = string

  let to_string s = s
  let of_string s = if s = "corrupt" then None else Some s
end)

let dir name = Filename.concat root name
let records name = Q.Records.create ~dir:(dir name)
let path name id = Filename.concat (dir name) id

(* Ids are minted with a timestamp and a sequence; planting them by hand keeps
   the order the cases expect legible. *)
let id n = Printf.sprintf "0000000000000000000%d-0000000%d-1" n n

let level = function
  | `debug -> "debug"
  | `info -> "info"
  | `warn -> "warn"
  | `err -> "err"
  | `critical -> "critical"

(* The exception's own spelling is the platform's, so what is asserted is that a
   record could not be read and which one, not how the OS phrased it. *)
let scrub msg =
  let tail = "; leaving" in
  let n = String.length msg and m = String.length tail in
  if n < m || String.sub msg (n - m) m <> tail then msg
  else (
    let head = String.sub msg 0 (n - m) in
    match String.rindex_opt head ':' with
      | Some i -> String.sub head 0 i ^ ": <exn>" ^ tail
      | None -> msg)

(* Only what this case logged: the buffer is process-wide and keeps everything.
   [Log.recent] answers newest first, so what is new is the front of it. *)
let seen = ref 0

let show_log () =
  let all = Log.recent () in
  let fresh =
    List.rev (List.filteri (fun i _ -> i < List.length all - !seen) all)
  in
  seen := List.length all;
  match fresh with
    | [] -> print_endline "  log              (nothing)"
    | lines ->
        List.iter
          (fun (_, l, msg) ->
            Printf.printf "  log              %s %s\n" (level l) (scrub msg))
          lines

let show name got =
  Printf.printf "  returned         %s\n"
    (match List.map snd got with
      | [] -> "(nothing)"
      | l -> String.concat ", " l);
  List.iter
    (fun n ->
      Printf.printf "  %-16s %s\n"
        ("record " ^ string_of_int n)
        (if Sys.file_exists (path name (id n)) then "on disk" else "gone"))
    [1; 2; 3];
  show_log ()

let case title = Printf.printf "=== %s\n" title

let plant name =
  let t = records name in
  let* () = Q.Records.write t ~id:(id 1) "one" in
  let* () = Q.Records.write t ~id:(id 2) "corrupt" in
  let+ () = Q.Records.write t ~id:(id 3) "three" in
  t

let () =
  Lwt_main.run
    (let* t = plant "skipped" in

     case "a record the caller does not want is not opened";
     let* got = Q.Records.list ~wanted:(fun _ -> false) t in
     show "skipped" got;

     case "and one it does want is read, and judged";
     let* got = Q.Records.list t in
     show "skipped" got;

     (* [wanted] runs before the body is opened, so completing the record there
        is the interleaving a working queue produces on every sweep. *)
     case "a record completed between the listing and the read";
     let* t = plant "raced" in
     let* got =
       Q.Records.list
         ~wanted:(fun i ->
           if i = id 2 then Sys.remove (path "raced" i);
           true)
         t
     in
     show "raced" got;

     (* A directory stands in for whatever else can refuse to be read — a full
        descriptor table, a bad sector — none of which say the work is not owed. *)
     case "a record that will not open for some other reason";
     let* t = plant "unreadable" in
     Sys.remove (path "unreadable" (id 2));
     Unix.mkdir (path "unreadable" (id 2)) 0o755;
     let* got = Q.Records.list t in
     show "unreadable" got;

     Lwt.return_unit)
