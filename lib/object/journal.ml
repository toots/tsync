type rename_op = {
  dst : string;
  src : string;
  size : int64 option;
  is_dir : bool;
  id : string option;  (** The folder's id, when [is_dir]. See {!op}. *)
}

(* Directory ops carry the folder's stable id alongside its path: applying a
   removal destroys the local marker the id would have been read from, so an id
   not recorded here cannot be recovered afterwards. *)
type op =
  [ `Delete of string
  | `Mkdir of string * string option
  | `Put of string * int64
  | `Rename of rename_op
  | `Rmdir of string * string option ]

(* ponytail: memoized and synchronous, to avoid threading Lwt through
   [entry_key], which is called on every journal write. *)
let uuid_cache : (string, string) Hashtbl.t = Hashtbl.create 1

let get_client_uuid ~share_dir =
  match Hashtbl.find_opt uuid_cache share_dir with
    | Some uuid -> uuid
    | None ->
        let uuid_file = Filename.concat share_dir "client-uuid" in
        let uuid =
          if Sys.file_exists uuid_file then (
            let ic = open_in uuid_file in
            let s = input_line ic in
            close_in ic;
            String.trim s)
          else (
            let uuid = Id.token 16 in
            Fs_util.mkdir_p_sync ~perm:0o700 share_dir;
            let oc = open_out uuid_file in
            output_string oc uuid;
            close_out oc;
            uuid)
        in
        Hashtbl.replace uuid_cache share_dir uuid;
        uuid

(* An entry key names one unit of work for its whole life — in the local WAL, in
   the backend journal, in the cursor a peer compares against. It had three
   string spellings (bare, prefixed, month-sharded) and correctness rested on
   every reader remembering which one it held; two forgot, and both bugs looked
   like a journal that was permanently behind.

   Abstract, so the spelling cannot vary: [of_string] is the only way in, and it
   accepts a listing entry or a stored line by taking the last path segment. *)
module Entry_key = struct
  type t = { ms : int64; client_uuid : string }

  (* %013Ld: 13-digit zero-padded int64, so lexicographic order matches
     chronological order, and the timestamp is bumped rather than repeated
     because two ops in one millisecond would collide as object names.

     ponytail: monotonic per process only; two processes sharing a client uuid
     (daemon + concurrent import) can still collide within one ms. *)
  let last_ms = ref 0L

  let make ~share_dir () =
    let now = Int64.of_float (Unix.gettimeofday () *. 1000.) in
    let ms = if now > !last_ms then now else Int64.add !last_ms 1L in
    last_ms := ms;
    { ms; client_uuid = get_client_uuid ~share_dir }

  let to_string { ms; client_uuid } = Printf.sprintf "%013Ld-%s" ms client_uuid

  (* The timestamp must be the full 13 digits {!to_string} writes: accepting a
     shorter one would make the month directory "2026-08" parse as an entry key
     of its own, and a listing that includes directories would report a shard as
     an entry. *)
  let ms_digits = 13

  let of_string s =
    let s = Filename.basename s in
    let uuid_at = ms_digits + 1 in
    if String.length s <= uuid_at || s.[ms_digits] <> '-' then None
    else (
      let ms = String.sub s 0 ms_digits in
      if not (String.for_all (fun c -> c >= '0' && c <= '9') ms) then None
      else
        Option.map
          (fun ms ->
            {
              ms;
              client_uuid = String.sub s uuid_at (String.length s - uuid_at);
            })
          (Int64.of_string_opt ms))

  let timestamp_ms { ms; _ } = ms
  let client_uuid { client_uuid; _ } = client_uuid

  (* Chronological, which is the order ops must be applied in. Ties break on the
     uuid only so the order is total; two clients writing in the same
     millisecond have no true order to recover. *)
  let compare a b =
    match Int64.compare a.ms b.ms with
      | 0 -> String.compare a.client_uuid b.client_uuid
      | c -> c

  (* Empty answers [true]: "no entries" is indistinguishable from "every entry
     that mattered was pruned", and a needless resync is cheaper than skipping
     the ops the pruning took. *)
  let cannot_bridge anchor = function
    | [] -> true
    | oldest :: _ -> Int64.compare oldest.ms anchor.ms > 0

  (* A month directory keeps the listing bounded — the journal only grows, one
     object per write — and costs readers nothing: shard and name both sort
     chronologically, which every cursor comparison depends on. *)
  let relative_path t =
    let tm = Unix.gmtime (Int64.to_float t.ms /. 1000.) in
    Printf.sprintf "%04d-%02d/%s" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
      (to_string t)
end

(* Omitted rather than written as null, so an older client reading a newer
   entry sees exactly what it saw before. *)
let dir_id_field = function None -> [] | Some id -> [("id", `String id)]

let to_json = function
  | `Put (key, size) ->
      `Assoc
        [
          ("op", `String "put");
          ("key", `String key);
          ("size", `Int (Int64.to_int size));
        ]
  | `Delete key -> `Assoc [("op", `String "delete"); ("key", `String key)]
  | `Mkdir (key, id) ->
      `Assoc ([("op", `String "mkdir"); ("key", `String key)] @ dir_id_field id)
  | `Rmdir (key, id) ->
      `Assoc ([("op", `String "rmdir"); ("key", `String key)] @ dir_id_field id)
  | `Rename { dst; src; size; is_dir; id } ->
      let fields =
        [
          ("op", `String "rename");
          ("key", `String dst);
          ("src", `String src);
          ("is_dir", `Bool is_dir);
        ]
        @ dir_id_field id
        @
          match size with
          | None -> []
          | Some s -> [("size", `Int (Int64.to_int s))]
      in
      `Assoc fields

let of_json j =
  try
    let open Yojson.Basic.Util in
    let key = j |> member "key" |> to_string in
    let dir_id =
      match j |> member "id" with `String s -> Some s | _ -> None
    in
    match j |> member "op" |> to_string with
      | "put" -> Some (`Put (key, j |> member "size" |> to_int |> Int64.of_int))
      | "delete" -> Some (`Delete key)
      | "mkdir" -> Some (`Mkdir (key, dir_id))
      | "rmdir" -> Some (`Rmdir (key, dir_id))
      | "rename" ->
          let src = j |> member "src" |> to_string in
          let size =
            match j |> member "size" with
              | `Int n -> Some (Int64.of_int n)
              | _ -> None
          in
          let is_dir =
            match j |> member "is_dir" with `Bool b -> b | _ -> false
          in
          Some (`Rename { dst = key; src; size; is_dir; id = dir_id })
      | _ -> None
  with _ -> None

let encode ops =
  String.concat "\n"
    (List.map (fun op -> Yojson.Basic.to_string (to_json op)) ops)
  ^ "\n"

let decode s =
  List.filter_map
    (fun line ->
      let line = String.trim line in
      if line = "" then None
      else (
        match Yojson.Basic.from_string line with
          | j -> of_json j
          | exception _ -> None))
    (String.split_on_char '\n' s)

module Make (C : Conf.S) = struct
  (* The client identity — uuid and entry keys — is shared across domains; the
     pending records {!Wal} keeps under it are per-domain. *)
  let share_dir = C.data_dir
  let client_uuid () = get_client_uuid ~share_dir
  let entry_key () = Entry_key.make ~share_dir ()
end
