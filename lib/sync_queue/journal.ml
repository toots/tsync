type rename_op = {
  dst : string;
  src : string;
  size : int64 option;
  is_dir : bool;
}

type op =
  [ `Delete of string
  | `Mkdir of string
  | `Put of string * int64
  | `Rename of rename_op
  | `Rmdir of string ]

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

(* %013Ld: 13-digit zero-padded int64; current ms timestamps are 13 digits,
   ensuring lexicographic order matches chronological order.
   Entry keys are backend object names: two ops in the same millisecond would
   collide and the second journal entry would overwrite the first, silently
   losing the op for other clients. Bump the timestamp to keep keys strictly
   increasing within this process.
   ponytail: monotonic per process only; two processes sharing a client uuid
   (daemon + concurrent import) can still collide within one ms. *)
let last_ms = ref 0L

let make_entry_key ~share_dir () =
  let now = Int64.of_float (Unix.gettimeofday () *. 1000.) in
  let ms = if now > !last_ms then now else Int64.add !last_ms 1L in
  last_ms := ms;
  Printf.sprintf "%013Ld-%s" ms (get_client_uuid ~share_dir)

let timestamp_ms_of_filename s =
  let s = Filename.basename s in
  let i = String.index s '-' in
  Int64.of_string (String.sub s 0 i)

let client_uuid_of_filename s =
  let s = Filename.basename s in
  let i = String.index s '-' in
  String.sub s (i + 1) (String.length s - i - 1)

(* Where an entry lives, relative to the journal prefix. A month directory keeps
   the listing bounded — the journal only ever grows, one object per write — and
   costs the readers nothing: entry names are zero-padded timestamps, so both the
   shard and the name within it sort chronologically, which is the order every
   cursor comparison depends on. The entry key itself is unchanged, so cursors
   and last-sync marks keep naming an entry the same way. *)
let relative_path entry_key =
  let ms = timestamp_ms_of_filename entry_key in
  let tm = Unix.gmtime (Int64.to_float ms /. 1000.) in
  Printf.sprintf "%04d-%02d/%s" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
    entry_key

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
    | `Mkdir key -> `Assoc [("op", `String "mkdir"); ("key", `String key)]
    | `Rmdir key -> `Assoc [("op", `String "rmdir"); ("key", `String key)]
    | `Rename { dst; src; size; is_dir } ->
        let fields =
          [
            ("op", `String "rename");
            ("key", `String dst);
            ("src", `String src);
            ("is_dir", `Bool is_dir);
          ]
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
          let op =
            match j |> member "op" |> to_string with
              | "put" -> `Put (key, j |> member "size" |> to_int |> Int64.of_int)
              | "delete" -> `Delete key
              | "mkdir" -> `Mkdir key
              | "rmdir" -> `Rmdir key
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
                  `Rename { dst = key; src; size; is_dir }
              | s -> failwith ("unknown op: " ^ s)
          in
          Some op
        with _ -> None))
    (String.split_on_char '\n' s)

(* Pending entries are per-domain: the ops they carry are domain-relative keys,
   so a shared queue would let one domain's [sync] replay another domain's
   entries against the wrong backend. *)
let pending_dir ~share_dir ~domain =
  Filename.concat (Filename.concat share_dir "journal-pending") domain

let write_local_pending ~share_dir ~domain ~entry_key ops =
  let open Lwt.Syntax in
  let dir = pending_dir ~share_dir ~domain in
  let* () = Fs_util.mkdir_p dir in
  Lwt_unix_retry.with_file ~mode:Lwt_io.Output (Filename.concat dir entry_key)
    (fun oc -> Lwt_io.write oc (encode ops))

let delete_local_pending ~share_dir ~domain ~entry_key =
  Fs_util.unlink_quiet
    (Filename.concat (pending_dir ~share_dir ~domain) entry_key)

let local_pending_entries ~share_dir ~domain ~uuid =
  let open Lwt.Syntax in
  let dir = pending_dir ~share_dir ~domain in
  let* exists = Lwt_unix_retry.file_exists dir in
  if not exists then Lwt.return_nil
  else
    let* names = Fs_util.readdir_list dir in
    names
    |> List.filter (fun name ->
        try client_uuid_of_filename name = uuid with _ -> false)
    |> List.sort String.compare
    |> Lwt_list.filter_map_s (fun name ->
        let path = Filename.concat dir name in
        Lwt.catch
          (fun () ->
            let+ s = Lwt_io.with_file ~mode:Lwt_io.Input path Lwt_io.read in
            Some (name, decode s))
          (fun _ -> Lwt.return_none))

module Make (C : Conf.S) = struct
  (* The client identity (uuid, entry keys) is shared across domains; the pending
     queue is scoped to this domain. *)
  let share_dir = C.data_dir
  let domain = C.domain_name
  let client_uuid () = get_client_uuid ~share_dir
  let entry_key () = make_entry_key ~share_dir ()

  let write_local_pending ~entry_key:ek ops =
    write_local_pending ~share_dir ~domain ~entry_key:ek ops

  let delete_local_pending ~entry_key:ek =
    delete_local_pending ~share_dir ~domain ~entry_key:ek

  let local_pending_entries ~uuid =
    local_pending_entries ~share_dir ~domain ~uuid
end
