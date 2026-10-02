open Tsync_core

type state = Intent | Prepared | Executed
type prior = Unknown | Nothing | Content of string

type record = {
  state : state;
  attempts : int;
  ops : Op.t list;
  priors : (int * prior) list;
  local_from : (int * string) list;
  fids : (int * string) list;
  last_error : (string * string) option;
}

let state_name = function
  | Intent -> "intent"
  | Prepared -> "prepared"
  | Executed -> "executed"

let encode r =
  let idx i = string_of_int i in
  Yojson.Safe.to_string
    (`Assoc
       ([
          ("state", `String (state_name r.state));
          ("attempts", `Int r.attempts);
          ("ops", Op.list_to_json r.ops);
        ]
       @ (match List.filter (fun (_, p) -> p <> Unknown) r.priors with
         | [] -> []
         | ps ->
             [
               ( "priors",
                 `Assoc
                   (List.map
                      (fun (i, p) ->
                        ( idx i,
                          match p with Content h -> `String h | _ -> `Null ))
                      ps) );
             ])
       @ (match r.local_from with
         | [] -> []
         | l ->
             [
               ( "localFrom",
                 `Assoc (List.map (fun (i, p) -> (idx i, `String p)) l) );
             ])
       @ (match r.fids with
         | [] -> []
         | l ->
             [
               ("fids", `Assoc (List.map (fun (i, id) -> (idx i, `String id)) l));
             ])
       @
         match r.last_error with
         | Some (k, d) ->
             [
               ("lastError", `Assoc [("kind", `String k); ("detail", `String d)]);
             ]
         | None -> []))

exception Unparseable

(* 04 §2.8: a record with an op this reader does not know is unparseable, never
   run with the op dropped. *)
let strict_op j =
  match Op.of_json j with
    | Some op -> op
    | None -> raise Unparseable
    | exception Op.Bad _ -> raise Unparseable

let decode body =
  try
    match Yojson.Safe.from_string body with
      | `Assoc f when List.mem_assoc "state" f ->
          let ops =
            match List.assoc_opt "ops" f with
              | Some (`List l) -> List.map strict_op l
              | _ -> raise Unparseable
          in
          let n = List.length ops in
          let index k =
            match int_of_string_opt k with
              | Some i when i >= 0 && i < n -> i
              | _ -> raise Unparseable
          in
          let state =
            match List.assoc_opt "state" f with
              | Some (`String "prepared") -> Prepared
              | Some (`String "executed") -> Executed
              | _ -> Intent
          in
          let priors =
            match List.assoc_opt "priors" f with
              | None -> []
              | Some (`Assoc l) ->
                  List.map
                    (fun (k, v) ->
                      ( index k,
                        match v with
                          | `Null -> Nothing
                          | `String h
                            when String.length h = 16
                                 && String.for_all Names.is_hexlower h ->
                              Content h
                          | _ -> raise Unparseable ))
                    l
              | _ -> raise Unparseable
          in
          let local_from =
            match List.assoc_opt "localFrom" f with
              | None -> []
              | Some (`Assoc l) ->
                  List.map
                    (fun (k, v) ->
                      match v with
                        | `String p -> (index k, p)
                        | _ -> raise Unparseable)
                    l
              | _ -> raise Unparseable
          in
          let fids =
            match List.assoc_opt "fids" f with
              | None -> []
              | Some (`Assoc l) ->
                  List.map
                    (fun (k, v) ->
                      match v with
                        | `String id when Names.valid_file_id id -> (index k, id)
                        | _ -> raise Unparseable)
                    l
              | _ -> raise Unparseable
          in
          let attempts =
            match List.assoc_opt "attempts" f with
              | Some (`Int a) when a >= 0 -> a
              | None -> 0
              | _ -> raise Unparseable
          in
          let last_error =
            match List.assoc_opt "lastError" f with
              | Some (`Assoc e) -> (
                  match
                    (List.assoc_opt "kind" e, List.assoc_opt "detail" e)
                  with
                    | Some (`String k), Some (`String d) -> Some (k, d)
                    | _ -> None)
              | _ -> None
          in
          Some { state; attempts; ops; priors; local_from; fids; last_error }
      | _ -> raise Unparseable
  with Unparseable | Yojson.Json_error _ -> (
    (* An op-list body: one op per line, meaning an intent with nothing
             else recorded. *)
    let lines =
      List.filter
        (fun l -> String.trim l <> "")
        (String.split_on_char '\n' body)
    in
    try
      let ops =
        List.map (fun l -> strict_op (Yojson.Safe.from_string l)) lines
      in
      if ops = [] then None
      else
        Some
          {
            state = Intent;
            attempts = 0;
            ops;
            priors = [];
            local_from = [];
            fids = [];
            last_error = None;
          }
    with _ -> None)

let is_metadata r = r.ops <> [] && not (List.exists Op.is_put r.ops)
let puts_only r = r.ops <> [] && List.for_all Op.is_put r.ops

let prior r i =
  match List.assoc_opt i r.priors with Some p -> p | None -> Unknown

(* The file an op names: what a file id follows when ops are rewritten. *)
let subject = function
  | Op.Put { path; _ } -> Some (`Put, path)
  | Delete path -> Some (`Delete, path)
  | Rename { is_dir = false; src; _ } -> Some (`Rename, src)
  | Mkdir _ | Rmdir _ | Rename _ -> None

let carry_fids r ops =
  let by_subject =
    List.filter_map
      (fun (i, id) ->
        Option.bind (List.nth_opt r.ops i) (fun op ->
            Option.map (fun s -> (s, id)) (subject op)))
      r.fids
  in
  List.concat
    (List.mapi
       (fun i op ->
         match
           Option.bind (subject op) (fun s -> List.assoc_opt s by_subject)
         with
           | Some id -> [(i, id)]
           | None -> [])
       ops)
