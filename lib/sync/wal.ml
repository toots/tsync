open Lwt.Syntax
module Ek = Journal.Entry_key

type state = Intent | Prepared | Executed

type record = {
  key : Ek.t;
  ops : Journal.op list;
  state : state;
  attempts : int;
  last_error : (Backend.kind * string) option;
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
  | "permanent" -> Backend.Permanent
  | _ -> Backend.Transient

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
                  ("kind", `String (Backend.string_of_kind kind));
                  ("detail", `String detail);
                ] );
          ])

(* Records written before the state was carried hold one op per line and no
   envelope. They read as [Intent], which is what they were: reconcile finds no
   staged data behind them and discards them. *)
let of_body key body =
  let legacy () =
    {
      key;
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
          key;
          ops;
          state = state_of_string (j |> member "state" |> to_string);
          attempts = (match j |> member "attempts" with `Int n -> n | _ -> 0);
          last_error;
        }
    | _ -> legacy ()
    | exception _ -> legacy ()

module Make (C : Conf.S) = struct
  module J = Journal.Make (C)

  (* One directory per domain: the ops carry domain-relative keys, so a shared
     store would let one domain's replay run another's entries against the wrong
     backend. *)
  let dir =
    Filename.concat (Filename.concat C.data_dir "journal-pending") C.domain_name

  let path key = Filename.concat dir (Ek.to_string key)

  let write r =
    let* () = Fs_util.mkdir_p dir in
    Fs_util.atomic_write (path r.key) (Yojson.Basic.to_string (to_json r))

  let read key =
    Lwt.catch
      (fun () ->
        let+ body =
          Lwt_io.with_file ~mode:Lwt_io.Input (path key) Lwt_io.read
        in
        Some (of_body key body))
      (fun _ -> Lwt.return_none)

  let record key ops =
    write { key; ops; state = Intent; attempts = 0; last_error = None }

  (* A record that is already gone is not an error: [complete] may have run
     before a straggling caller. *)
  let update key f =
    let* r = read key in
    match r with None -> Lwt.return_unit | Some r -> write (f r)

  let advance key state = update key (fun r -> { r with state })

  let note_failure key kind detail =
    update key (fun r ->
        { r with attempts = r.attempts + 1; last_error = Some (kind, detail) })

  let complete key = Fs_util.unlink_quiet (path key)

  let list () =
    let uuid = J.client_uuid () in
    let* exists = Lwt_unix_retry.file_exists dir in
    if not exists then Lwt.return_nil
    else
      let* names = Fs_util.readdir_list dir in
      names
      |> List.filter_map Ek.of_string
      |> List.filter (fun key -> Ek.client_uuid key = uuid)
      |> List.sort Ek.compare |> Lwt_list.filter_map_s read
end
