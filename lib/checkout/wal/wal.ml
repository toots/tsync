open Lwt.Syntax
module Ek = Journal.Entry_key

type state = Intent | Prepared | Executed

type record = {
  ops : Journal.op list;
  state : state;
  attempts : int;
  last_error : (Retry.kind * string) option;
}

let string_of_state = function
  | Intent -> "intent"
  | Prepared -> "prepared"
  | Executed -> "executed"

(* An unrecognised state reads as [Intent]: reconcile then decides from what is
   actually on disk and on the backend, which is always safe. Claiming a later
   state than the record earned would skip the work it names. *)
let state_of_string = function
  | "prepared" -> Prepared
  | "executed" -> Executed
  | _ -> Intent

let kind_of_string = function
  | "permanent" -> Retry.Permanent
  | _ -> Retry.Transient

let to_json r =
  `Assoc
    ([
       ("state", `String (string_of_state r.state));
       ("attempts", `Int r.attempts);
       ("ops", `List (List.map Journal.to_json r.ops));
     ]
    @
      match r.last_error with
      | None -> []
      | Some (kind, detail) ->
          [
            ( "lastError",
              `Assoc
                [
                  ("kind", `String (Retry.string_of_kind kind));
                  ("detail", `String detail);
                ] );
          ])

(* A record with no envelope — one op per line — reads as [Intent], so reconcile
   finds no staged data behind it and discards it. *)
let of_body body =
  let legacy () =
    {
      ops = Journal.decode body;
      state = Intent;
      attempts = 0;
      last_error = None;
    }
  in
  match Yojson.Basic.from_string body with
    | `Assoc fields when List.mem_assoc "state" fields ->
        let open Yojson.Basic.Util in
        let j = `Assoc fields in
        let ops =
          match j |> member "ops" with
            | `List l -> List.filter_map Journal.of_json l
            | _ -> []
        in
        let last_error =
          match j |> member "lastError" with
            | `Assoc _ as e ->
                Some
                  ( kind_of_string (e |> member "kind" |> to_string),
                    e |> member "detail" |> to_string )
            | _ -> None
        in
        {
          ops;
          state = state_of_string (j |> member "state" |> to_string);
          attempts = (match j |> member "attempts" with `Int n -> n | _ -> 0);
          last_error;
        }
    | _ -> legacy ()
    | exception _ -> legacy ()

(* The record is the durable job the upload queue drains, so it is a
   {!Durable_queue_lwt.JOB} rather than a format this module reads and writes
   itself. *)
module Job = struct
  type t = record

  let to_string r = Yojson.Basic.to_string (to_json r)
  let of_string body = Some (of_body body)
end

module Q = Durable_queue_lwt.Make (Job)

(* The records of a domain are one thing however many places name them: this
   functor is applied wherever the log is read or written, and a second
   [Records.t] over the same directory would keep its own id counter. *)
(* A hand-off between a file operation, which writes a record, and whoever
   sends the bytes, which is a worker pool with a width of its own. It holds
   what it is told: a condition alone drops a signal sent while nobody is
   waiting, and here that would be work nobody comes back for. *)
(* A hand-off between a file operation, which writes a record, and whoever
   sends the bytes, which is a worker pool with a width of its own.

   The taker is installed rather than waited on. A file operation must not stall
   where nothing is draining -- the record is already written, so the work
   survives either way -- and it must not return before the work is taken up,
   or a delete arriving straight after a close finds no upload to cancel. *)
module Owed = struct
  type 'a t = { mutable take : 'a -> unit Lwt.t }

  let create () = { take = (fun _ -> Lwt.return_unit) }
  let consume t take = t.take <- take
  let idle t = t.take <- (fun _ -> Lwt.return_unit)
  let signal t x = t.take x
end

let logs : (string, Q.Records.t * (Ek.t * record) Owed.t) Hashtbl.t =
  Hashtbl.create 4

let log_for dir =
  match Hashtbl.find_opt logs dir with
    | Some both -> both
    | None ->
        let both = (Q.Records.create ~dir, Owed.create ()) in
        Hashtbl.replace logs dir both;
        both

module Make (C : Conf.S) = struct
  module J = Journal.Make (C)

  (* One directory per domain: the ops carry domain-relative keys, so a shared
     store would let one domain's replay run another's entries against the wrong
     backend. *)
  let log, owed =
    log_for
      (Filename.concat
         (Filename.concat C.data_dir "journal-pending")
         C.domain_name)

  (* An entry key names one unit of work for its whole life — here, in the
     backend journal, and in the cursor a peer compares against — so it is the
     record's id rather than something minted per queue. *)
  let id = Ek.to_string
  let write key r = Q.Records.write log ~id:(id key) r

  let record key ops =
    write key { ops; state = Intent; attempts = 0; last_error = None }

  let advance key state =
    Q.Records.update log (id key) (fun r -> { r with state })

  let note_failure key kind detail =
    Q.Records.update log (id key) (fun r ->
        { r with attempts = r.attempts + 1; last_error = Some (kind, detail) })

  let complete key = Q.Records.complete log (id key)

  (* Executed, then published, then peers told to look, then the record goes: a
     crash in any of those windows leaves a record reconcile can finish from
     what the backend says. Dropping the record first would leave the work done,
     no entry for peers to read, and nothing saying anything was owed.

     Where the entry goes and how the cursor moves are the store's, not this
     log's: a caller that publishes on a timer passes a different [cursor] from
     one discharging a single operation in its own path. *)
  let discharge ~publish ~cursor key ops =
    let* () = advance key Executed in
    let* (_ : Journal.Entry_key.t) = publish key ops in
    let* () = cursor key in
    complete key

  (* Ours alone: another client's records are its own to reconcile, and the
     directory is per domain rather than per client. *)
  let list () =
    let uuid = J.client_uuid () in
    let open Lwt.Syntax in
    let+ records = Q.Records.list log in
    records
    |> List.filter_map (fun (id, r) ->
        Option.map (fun key -> (key, r)) (Ek.of_string id))
    |> List.filter (fun (key, _) -> Ek.client_uuid key = uuid)
    |> List.sort (fun (a, _) (b, _) -> Ek.compare a b)
end
