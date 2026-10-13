open Tsync_core

type in_flight = { n : int; body : string }

type step =
  | Move of Algebra.place * Algebra.place
  | File of Algebra.place * Manifest.t option
  | Folder of Folder_id.t * Algebra.place option

type settled =
  | Drop
  | Before_file of Log_entry.value option
  | Before_folder of Algebra.place option

type arrival = {
  head : int;
  view : Folder_id.t option;
  steps : step list;
  before : (Algebra.key * settled) list;
}

module Keys = Map.Make (struct
  type t = Algebra.key

  let compare = Algebra.compare_key
end)

type t = {
  dir : string;
  m : Mutex.t;
  mutable before : settled Keys.t;
  mutable soft : unit Keys.t;
  mutable needs_state : bool;
}

let ( let* ) = Option.bind
let ok = Result.to_option
let file t name = Filename.concat t.dir name
let before_dir t = file t "before"

let record_name : Algebra.key -> string = function
  | `File p ->
      Printf.sprintf "f-%s-%s" (Folder_id.to_string p.parent) (Xxh.dual p.name)
  | `Folder i -> "d-" ^ Folder_id.to_string i

let before_path t key = Filename.concat (before_dir t) (record_name key)

let settled_fields = function
  | Drop -> [("drop", `Bool true)]
  (* 03 §2.8: no value of [before] reads as an identity, so this one reads
     back as unknown. *)
  | Before_file (Some Unknown) -> [("before", `String "unknown")]
  | Before_file v -> [("before", Log_entry.guard_to_json v)]
  | Before_folder p -> [("before", Log_entry.place_to_json p)]

(* An unknown before-value differs from every value: only an arrival by state,
   which reads the main's value at its key, replaces it. *)
let unknown = function Before_file (Some Unknown) -> true | _ -> false

let encode_before key value =
  Yojson.Safe.to_string
    (`Assoc (Log_entry.key_fields key @ settled_fields value))

let settled_of_json json : (Algebra.key * settled) option =
  let* key = ok (Log_entry.key_of_json json) in
  let field name =
    match json with `Assoc l -> List.assoc_opt name l | _ -> None
  in
  match (field "drop", field "before", key) with
    | Some (`Bool true), _, _ -> Some (key, Drop)
    | _, Some v, `File _ ->
        Some
          ( key,
            Before_file
              (match Log_entry.guard_of_json v with
                | Ok v -> v
                | Error _ -> Some Unknown) )
    | _, Some v, `Folder _ ->
        let* p = ok (Log_entry.place_of_json v) in
        Some (key, Before_folder p)
    | _, None, _ -> None

let decode_before body =
  match Yojson.Safe.from_string body with
    | exception _ -> None
    | json -> (
        match settled_of_json json with
          | Some (_, Drop) | None -> None
          | some -> some)

let set_aside t path =
  let rec pick n =
    let name =
      if n = 1 then path ^ ".bad" else Printf.sprintf "%s.bad.%d" path n
    in
    if Fs.exists name then pick (n + 1) else name
  in
  let name = pick 1 in
  Fs.rename path name;
  Fs.fsync_dir (Filename.dirname path);
  t.needs_state <- true;
  Log.warn "%s does not decode; set aside as %s" path (Filename.basename name)

let is_record name =
  String.length name > 2
  && (name.[0] = 'f' || name.[0] = 'd')
  && name.[1] = '-'
  && not (Text.contains name ".bad")

let open_ ~data_dir domain =
  let dir =
    List.fold_left Filename.concat data_dir
      ["sync"; Domain_name.to_string domain]
  in
  let t =
    {
      dir;
      m = Mutex.create ();
      before = Keys.empty;
      soft = Keys.empty;
      needs_state = false;
    }
  in
  Fs.mkdir_p ~perm:0o700 (before_dir t);
  List.iter
    (fun name ->
      let path = Filename.concat (before_dir t) name in
      if is_record name then (
        match Option.bind (Fs.read_file_opt path) decode_before with
          | Some (key, value) when record_name key = name ->
              if unknown value then t.needs_state <- true;
              t.before <- Keys.add key value t.before
          | _ -> set_aside t path))
    (Fs.readdir (before_dir t));
  t

let needs_state t = t.needs_state
let state_read t = t.needs_state <- false

let read_record t name decode =
  let path = file t name in
  match Fs.read_file_opt path with
    | None -> None
    | Some body -> (
        match decode body with
          | Some _ as v -> v
          | None ->
              set_aside t path;
              None)

let position t =
  read_record t "position" (fun s -> int_of_string_opt (String.trim s))

let set_position t n =
  Fs.durable_replace (file t "position") (Key.entry_number n)

let find t key = Mutex.protect t.m (fun () -> Keys.find_opt key t.before)

let before_file t p =
  match find t (`File p) with Some (Before_file v) -> Some v | _ -> None

let before_folder t i =
  match find t (`Folder i) with Some (Before_folder p) -> Some p | _ -> None

let write ?(durable = true) t key value =
  let path = before_path t key and body = encode_before key value in
  if durable then Fs.durable_replace ~perm:0o600 path body
  else Fs.replace ~perm:0o600 path body;
  Mutex.protect t.m (fun () ->
      if unknown value then t.needs_state <- true;
      t.before <- Keys.add key value t.before;
      t.soft <-
        (if durable then Keys.remove key t.soft else Keys.add key () t.soft))

let record ?durable t key value =
  if find t key = None then write ?durable t key value

let record_file ?durable t p v = record ?durable t (`File p) (Before_file v)
let record_folder t i p = record t (`Folder i) (Before_folder p)
let set_file t p v = write t (`File p) (Before_file v)
let set_folder t i p = write t (`Folder i) (Before_folder p)

let drop t key =
  if find t key <> None then (
    ignore (Fs.release (before_path t key));
    Fs.fsync_dir (before_dir t);
    Mutex.protect t.m (fun () ->
        t.before <- Keys.remove key t.before;
        t.soft <- Keys.remove key t.soft))

let harden t key =
  match
    Mutex.protect t.m (fun () ->
        (Keys.mem key t.soft, Keys.find_opt key t.before))
  with
    | true, Some value -> write t key value
    | _ -> ()

let pending t : Log_entry.command list =
  Keys.fold
    (fun key value acc ->
      match (key, value) with
        | `File p, Before_file v -> `File (p, v, None) :: acc
        | `Folder i, Before_folder p -> `Folder (i, p, None) :: acc
        | _ -> acc)
    (Mutex.protect t.m (fun () -> t.before))
    []
  |> List.rev

let pending_count t = Keys.cardinal (Mutex.protect t.m (fun () -> t.before))

let in_flight t =
  read_record t "in-flight" (fun s ->
      match Yojson.Safe.from_string s with
        | `Assoc l -> (
            match (List.assoc_opt "n" l, List.assoc_opt "body" l) with
              | Some (`Int n), Some (`String b) ->
                  let* body = ok (Base64.decode b) in
                  Some { n; body }
              | _ -> None)
        | _ | (exception _) -> None)

let set_in_flight t { n; body } =
  Fs.durable_replace ~perm:0o600 (file t "in-flight")
    (Yojson.Safe.to_string
       (`Assoc [("n", `Int n); ("body", `String (Base64.encode_string body))]))

let clear t name = if Fs.release (file t name) then Fs.fsync_dir t.dir
let clear_in_flight t = clear t "in-flight"

let step_to_json : step -> Yojson.Safe.t = function
  | Move (src, dst) ->
      `Assoc
        [
          ("move", Log_entry.place_to_json (Some src));
          ("to", Log_entry.place_to_json (Some dst));
        ]
  | File (p, m) ->
      `Assoc
        (Log_entry.key_fields (`File p)
        @ [
            ( "value",
              Log_entry.manifest_to_json ~leaf:p.name
                (Option.map (fun m -> Log_entry.Known m) m) );
          ])
  | Folder (i, p) ->
      `Assoc
        (Log_entry.key_fields (`Folder i)
        @ [("value", Log_entry.place_to_json p)])

let step_of_json json =
  let field name =
    match json with `Assoc l -> List.assoc_opt name l | _ -> None
  in
  let place name =
    let* v = field name in
    Option.join (ok (Log_entry.place_of_json v))
  in
  match (place "move", place "to") with
    | Some src, Some dst -> Some (Move (src, dst))
    | _ -> (
        let* value = field "value" in
        match ok (Log_entry.key_of_json json) with
          | Some (`File p) -> (
              match Log_entry.manifest_of_json value with
                | Ok None -> Some (File (p, None))
                | Ok (Some (Known m)) -> Some (File (p, Some m))
                | _ -> None)
          | Some (`Folder i) ->
              let* place = ok (Log_entry.place_of_json value) in
              Some (Folder (i, place))
          | None -> None)

let encode_arrival a =
  Yojson.Safe.to_string
    (`Assoc
       ((match a.view with
          | Some id -> [("view", `String (Folder_id.to_string id))]
          | None -> [])
       @ [
           ("head", `Int a.head);
           ("steps", `List (List.map step_to_json a.steps));
           ( "before",
             `List
               (List.map
                  (fun (key, value) ->
                    `Assoc (Log_entry.key_fields key @ settled_fields value))
                  a.before) );
         ]))

let all f l =
  List.fold_right
    (fun x acc ->
      let* acc = acc in
      let* x = f x in
      Some (x :: acc))
    l (Some [])

let decode_arrival body =
  match Yojson.Safe.from_string body with
    | exception _ -> None
    | `Assoc l -> (
        match
          ( List.assoc_opt "head" l,
            List.assoc_opt "steps" l,
            List.assoc_opt "before" l )
        with
          | Some (`Int head), Some (`List steps), Some (`List before) ->
              let* steps = all step_of_json steps in
              let* before = all settled_of_json before in
              let view =
                match List.assoc_opt "view" l with
                  | Some (`String id) -> Folder_id.of_string id
                  | _ -> None
              in
              Some { head; view; steps; before }
          | _ -> None)
    | _ -> None

let arrival t = read_record t "arrival" decode_arrival

let set_arrival t a =
  Fs.durable_replace ~perm:0o600 (file t "arrival") (encode_arrival a)

let clear_arrival t = clear t "arrival"
