type rename_op = {
  dst : string;
  src : string;
  size : int64 option;
  is_dir : bool;
  id : string option;  (** The folder's id, when [is_dir]. See {!op}. *)
}

(* Directory ops carry the folder's stable id alongside its path: applying a
   removal destroys the local marker the id would have been read from, so an id
   not recorded here cannot be recovered and the folder cannot be named to
   anything that knows it by id. [None] for entries written before this was
   carried, and for a client with no id for the folder. *)
type op =
  [ `Delete of string
  | `Mkdir of string * string option
  | `Put of string * int64
  | `Rename of rename_op
  | `Rmdir of string * string option ]

(* ponytail: the client uuid is stable for the process lifetime, so it is read
   (or generated) once and memoized. Keeping it synchronous avoids threading Lwt
   through entry_key, which is called on every journal write. *)
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
     chronological order at current ms timestamps.
     Entry keys are backend object names, so two ops in the same millisecond
     would collide and the second entry would overwrite the first. The timestamp
     is bumped to keep keys strictly increasing within this process.
     ponytail: monotonic per process only; two processes sharing a client uuid
     (daemon + concurrent import) can still collide within one ms. *)
  let last_ms = ref 0L

  let make ~share_dir () =
    let now = Int64.of_float (Unix.gettimeofday () *. 1000.) in
    let ms = if now > !last_ms then now else Int64.add !last_ms 1L in
    last_ms := ms;
    { ms; client_uuid = get_client_uuid ~share_dir }

  let to_string { ms; client_uuid } = Printf.sprintf "%013Ld-%s" ms client_uuid

  (* [None] rather than an exception: the callers are listings and stored files,
     where a name nobody wrote is a thing to report, not to crash on.

     The timestamp must be the full 13 digits {!to_string} writes. Accepting a
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

  (* A month directory keeps the listing bounded — the journal only grows, one
     object per write — and costs readers nothing: entry names are zero-padded
     timestamps, so shard and name both sort chronologically, which every cursor
     comparison depends on. The entry key itself is unchanged. *)
  let relative_path t =
    let tm = Unix.gmtime (Int64.to_float t.ms /. 1000.) in
    Printf.sprintf "%04d-%02d/%s" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
      (to_string t)
end

(* Omitted rather than written as null, so an older client reading a newer
   entry sees exactly what it saw before. *)
let dir_id_field = function None -> [] | Some id -> [("id", `String id)]

let encode ops =
  let encode_one = function
    | `Put (key, size) ->
        `Assoc
          [
            ("op", `String "put");
            ("key", `String key);
            ("size", `Int (Int64.to_int size));
          ]
    | `Delete key -> `Assoc [("op", `String "delete"); ("key", `String key)]
    | `Mkdir (key, id) ->
        `Assoc
          ([("op", `String "mkdir"); ("key", `String key)] @ dir_id_field id)
    | `Rmdir (key, id) ->
        `Assoc
          ([("op", `String "rmdir"); ("key", `String key)] @ dir_id_field id)
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
  in
  String.concat "\n"
    (List.map (fun op -> Yojson.Basic.to_string (encode_one op)) ops)
  ^ "\n"

let decode s =
  List.filter_map
    (fun line ->
      let line = String.trim line in
      if line = "" then None
      else (
        try
          let open Yojson.Basic.Util in
          let j = Yojson.Basic.from_string line in
          let key = j |> member "key" |> to_string in
          let dir_id =
            match j |> member "id" with `String s -> Some s | _ -> None
          in
          let op =
            match j |> member "op" |> to_string with
              | "put" -> `Put (key, j |> member "size" |> to_int |> Int64.of_int)
              | "delete" -> `Delete key
              | "mkdir" -> `Mkdir (key, dir_id)
              | "rmdir" -> `Rmdir (key, dir_id)
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
                  `Rename { dst = key; src; size; is_dir; id = dir_id }
              | s -> failwith ("unknown op: " ^ s)
          in
          Some op
        with _ -> None))
    (String.split_on_char '\n' s)

(* Per-domain: the ops carry domain-relative keys, so a shared queue would let
   one domain's [sync] replay another's entries against the wrong backend. *)
let pending_dir ~share_dir ~domain =
  Filename.concat (Filename.concat share_dir "journal-pending") domain

let pending_path ~share_dir ~domain entry_key =
  Filename.concat
    (pending_dir ~share_dir ~domain)
    (Entry_key.to_string entry_key)

let write_local_pending ~share_dir ~domain ~entry_key ops =
  let open Lwt.Syntax in
  let* () = Fs_util.mkdir_p (pending_dir ~share_dir ~domain) in
  Lwt_unix_retry.with_file ~mode:Lwt_io.Output
    (pending_path ~share_dir ~domain entry_key) (fun oc ->
      Lwt_io.write oc (encode ops))

let delete_local_pending ~share_dir ~domain ~entry_key =
  Fs_util.unlink_quiet (pending_path ~share_dir ~domain entry_key)

let local_pending_entries ~share_dir ~domain ~uuid =
  let open Lwt.Syntax in
  let dir = pending_dir ~share_dir ~domain in
  let* exists = Lwt_unix_retry.file_exists dir in
  if not exists then Lwt.return_nil
  else
    let* names = Fs_util.readdir_list dir in
    names
    |> List.filter_map Entry_key.of_string
    |> List.filter (fun ek -> Entry_key.client_uuid ek = uuid)
    |> List.sort Entry_key.compare
    |> Lwt_list.filter_map_s (fun ek ->
        let path = pending_path ~share_dir ~domain ek in
        Lwt.catch
          (fun () ->
            let+ s = Lwt_io.with_file ~mode:Lwt_io.Input path Lwt_io.read in
            Some (ek, decode s))
          (fun _ -> Lwt.return_none))

module Make (C : Conf.S) = struct
  (* The client identity (uuid, entry keys) is shared across domains; the pending
     queue is scoped to this domain. *)
  let share_dir = C.data_dir
  let domain = C.domain_name
  let client_uuid () = get_client_uuid ~share_dir
  let entry_key () = Entry_key.make ~share_dir ()

  let write_local_pending ~entry_key:ek ops =
    write_local_pending ~share_dir ~domain ~entry_key:ek ops

  let delete_local_pending ~entry_key:ek =
    delete_local_pending ~share_dir ~domain ~entry_key:ek

  let local_pending_entries ~uuid =
    local_pending_entries ~share_dir ~domain ~uuid
end
