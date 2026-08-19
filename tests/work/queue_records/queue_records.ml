(* What a sweep of the record directory reads, and what it deletes.

   Both are asked with a deliberately corrupt record, because it is the one
   whose fate says whether its body was opened at all: a sweep that reads it
   discards it, and a sweep that skipped it on its id alone leaves it where it
   was.

   Nothing here reads a clock, and log lines are printed without their
   timestamps, so the output is the same on any machine. *)

open Lwt.Syntax

let root = Scratch.dir "queue-records"

module Q = Durable_queue.Make (struct
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
            Printf.printf "  log              %s %s\n" (level l) msg)
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

     Lwt.return_unit)
