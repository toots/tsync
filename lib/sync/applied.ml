open Tsync_core

type t = {
  dir : string;
  m : Mutex.t;
  handled : (string, unit) Hashtbl.t;
  mutable head : Entry_key.t option;
}

let open_ dir =
  { dir; m = Mutex.create (); handled = Hashtbl.create 4096; head = None }

let shards t =
  List.filter
    (fun n -> String.length n = 11 && String.ends_with ~suffix:".log" n)
    (Fs.readdir t.dir)

type op = { op : Op.t; fid : string option }

let fid_of = function
  | `Assoc f -> (
      match List.assoc_opt "fid" f with
        | Some (`String id) when Names.valid_file_id id -> Some id
        | _ -> None)
  | _ -> None

let op_to_json ?fid op =
  match (Op.to_json op, fid) with
    | `Assoc f, Some id -> `Assoc (f @ [("fid", `String id)])
    | j, _ -> j

(* A line with no tab, a key that does not parse or a second field that is not
   an array is a torn record, dropped. *)
let parse_line l =
  match String.index_opt l '\t' with
    | None -> None
    | Some i -> (
        match Entry_key.parse (String.sub l 0 i) with
          | None -> None
          | Some k -> (
              match
                Yojson.Safe.from_string
                  (String.sub l (i + 1) (String.length l - i - 1))
              with
                | `List l ->
                    Some
                      ( k,
                        List.filter_map
                          (fun j ->
                            match Op.of_json j with
                              | Some op -> Some { op; fid = fid_of j }
                              | None | (exception Op.Bad _) -> None)
                          l )
                | _ -> None
                | exception _ -> None))

let lines_of t shard =
  List.filter_map parse_line
    (String.split_on_char '\n'
       (Option.value ~default:""
          (Fs.read_file_opt (Filename.concat t.dir shard))))

let fold t f acc =
  List.fold_left
    (fun acc shard -> List.fold_left f acc (lines_of t shard))
    acc (shards t)

let load t =
  let head = ref None in
  fold t
    (fun () (k, _) ->
      Hashtbl.replace t.handled (Entry_key.to_string k) ();
      head := Some k)
    ();
  Mutex.protect t.m (fun () -> t.head <- !head)

let contains t k =
  Mutex.protect t.m (fun () -> Hashtbl.mem t.handled (Entry_key.to_string k))

let keys t =
  Mutex.protect t.m (fun () ->
      Hashtbl.fold
        (fun k () acc -> Option.get (Entry_key.parse k) :: acc)
        t.handled [])

let head t = Mutex.protect t.m (fun () -> t.head)

let current_shard () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d.log" (tm.tm_year + 1900) (tm.tm_mon + 1)

(* The newline leads, so a record torn by a crash is closed by the next
   append and only that record is lost. *)
let note ?(fids = []) t k ops =
  Mutex.protect t.m (fun () ->
      if not (Hashtbl.mem t.handled (Entry_key.to_string k)) then (
        Fs.mkdir_p t.dir;
        Fs.append_durable
          (Filename.concat t.dir (current_shard ()))
          ("\n" ^ Entry_key.to_string k ^ "\t"
          ^ Yojson.Safe.to_string
              (`List
                 (List.mapi
                    (fun i op -> op_to_json ?fid:(List.assoc_opt i fids) op)
                    ops)));
        Hashtbl.replace t.handled (Entry_key.to_string k) ();
        t.head <- Some k))

type page = { entries : (Entry_key.t * op list) list; more : bool }

(* Positions are line order, the earliest line of a key being its position. *)
let since t anchor limit =
  let all = List.rev (fold t (fun acc (k, ops) -> (k, ops) :: acc) []) in
  let seen = Hashtbl.create 64 in
  let all =
    List.filter
      (fun (k, _) ->
        if Hashtbl.mem seen k then false
        else (
          Hashtbl.replace seen k ();
          true))
      all
  in
  let rest =
    match anchor with
      | None -> Some all
      | Some a ->
          let rec drop = function
            | [] -> None
            | (k, _) :: tl -> if Entry_key.equal k a then Some tl else drop tl
          in
          drop all
  in
  match rest with
    | None -> `Stale
    | Some rest ->
        let entries = List.filteri (fun i _ -> i < limit) rest in
        `Page { entries; more = List.length rest > limit }

(* wal-and-journal §4.8: a shard goes only when it is not the newest and every
   key in it is older than [horizon] + [slack]. *)
let prune t ~now ~keep =
  let all = shards t in
  let newest = List.fold_left max "" all in
  List.fold_left
    (fun removed shard ->
      if shard = newest then removed
      else (
        let lines = lines_of t shard in
        if
          List.for_all
            (fun (k, _) ->
              Int64.to_float (Entry_key.ms k) /. 1000. < now -. keep)
            lines
        then (
          ignore (Fs.release (Filename.concat t.dir shard));
          Mutex.protect t.m (fun () ->
              List.iter
                (fun (k, _) -> Hashtbl.remove t.handled (Entry_key.to_string k))
                lines);
          removed + 1)
        else removed))
    0 all
