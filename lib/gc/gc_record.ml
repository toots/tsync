open Tsync_core
open Tsync_store

type phase = Opening | Marking | Closing | Abandoning

type t = {
  phase : phase;
  started : float;
  cursor : string;
  generation : int option;
}

type read = Absent | Unreadable | Record of t

let phase_name = function
  | Opening -> "opening"
  | Marking -> "marking"
  | Closing -> "closing"
  | Abandoning -> "abandoning"

let phase_of_name = function
  | "opening" -> Some Opening
  | "marking" -> Some Marking
  | "closing" | "reconciling" -> Some Closing
  | "abandoning" -> Some Abandoning
  | _ -> None

let decode body =
  match Yojson.Safe.from_string body with
    | `Assoc f -> (
        let started =
          match List.assoc_opt "started" f with
            | Some (`Float s) -> Some s
            | Some (`Int s) -> Some (float_of_int s)
            | _ -> None
        and phase =
          match List.assoc_opt "phase" f with
            | Some (`String p) -> phase_of_name p
            | _ -> None
        and cursor =
          match List.assoc_opt "cursor" f with
            | Some (`String c) -> Some c
            | None -> Some ""
            | Some _ -> None
        and generation =
          match List.assoc_opt "generation" f with
            | Some (`Int g) when g >= 1 -> Some (Some g)
            | None -> Some None
            | Some _ -> None
        in
        match (phase, started, cursor, generation) with
          | Some phase, Some started, Some cursor, Some generation ->
              Record { phase; started; cursor; generation }
          | _ -> Unreadable)
    | _ -> Unreadable
    | exception _ -> Unreadable

let encode r =
  Yojson.Safe.to_string
    (`Assoc
       ([
          ("phase", `String (phase_name r.phase));
          ("started", `Float r.started);
          ("cursor", `String r.cursor);
        ]
       @ Option.fold ~none:[]
           ~some:(fun g -> [("generation", `Int g)])
           r.generation))

let read (main : Store.t) d =
  match main.get_opt (Key.gc_run d) with
    | None -> Absent
    | Some b -> decode (Bigstring.to_string b)

let write (main : Store.t) d r =
  main.put (Key.gc_run d) (Bigstring.of_string (encode r))

let clear (main : Store.t) d = ignore (main.delete (Key.gc_run d))
let run_name r = Key.run_name r.started
