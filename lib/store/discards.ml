open Tsync_core

type pending = {
  run : string;
  shard : string;
  generation : int;
  keys : string list;
}
[@@deriving yojson]

type t = { records : Dqueue.Records.t; m : Mutex.t }

let open_ ~dir =
  { records = Dqueue.Records.open_ (dir ^ ".discards"); m = Mutex.create () }

let decode body =
  match pending_of_yojson (Yojson.Safe.from_string body) with
    | Ok p -> Some p
    | Error _ -> None
    | exception _ -> None

let pending t =
  List.filter_map
    (fun id ->
      match Dqueue.Records.read t.records id with
        | `Body b -> Option.map (fun p -> (id, p)) (decode b)
        | `Gone -> None)
    (Dqueue.Records.list t.records)

let encode p = Yojson.Safe.to_string (pending_to_yojson p)

(* replication §4.8: a later batch of the same run and shard supersedes the
   request, so the record grows to cover both. *)
let same_request t p =
  List.find_opt (fun (_, q) -> q.run = p.run && q.shard = p.shard) (pending t)

let add t p ~write =
  let merged =
    Mutex.protect t.m (fun () ->
        let keys =
          match same_request t p with
            | Some (_, q) -> q.keys @ p.keys
            | None -> p.keys
        in
        { p with keys = List.sort_uniq String.compare keys })
  in
  write merged;
  Mutex.protect t.m (fun () ->
      match same_request t merged with
        | Some (id, _) -> Dqueue.Records.replace t.records id (encode merged)
        | None -> ignore (Dqueue.Records.create t.records (encode merged)))

let remove t id = Dqueue.Records.complete t.records id
let request_key d p = Key.discard_job d ~run:p.run ~shard:p.shard
let body keys = Bigstring.of_string (String.concat "\n" keys)

let keys_of_body b =
  List.filter_map
    (fun l -> match String.trim l with "" -> None | l -> Key.of_string l)
    (String.split_on_char '\n' (Bigstring.to_string b))
