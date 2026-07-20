(* One-off, unchecked migration: converts a backend from the ORIGINAL real-path
   key layout (manifests/<percent-encoded-realpath>, no [name] in the body) to
   the inode layout (manifests/<folder_id>/<hash(leaf)> + folder markers). Run
   once per domain, against a BACKUP first. Not built by the default target or
   tests.

   Usage: migrate <config.json> [domain]

   Folder ids are minted once and shared across a domain's backends, so every
   backend maps a given folder to the same id. *)

open Lwt.Syntax

(* Reverse the retired per-component percent-encoding. *)
let decode s =
  let n = String.length s in
  let buf = Buffer.create n in
  let i = ref 0 in
  while !i < n do
    if s.[!i] = '%' && !i + 2 < n then (
      match int_of_string_opt ("0x" ^ String.sub s (!i + 1) 2) with
        | Some c ->
            Buffer.add_char buf (Char.chr c);
            i := !i + 3
        | None ->
            Buffer.add_char buf s.[!i];
            incr i)
    else (
      Buffer.add_char buf s.[!i];
      incr i)
  done;
  Buffer.contents buf

let parent rel = match Filename.dirname rel with "." -> "" | d -> d

(* Folder id derived deterministically from the real folder path, so the tool is
   idempotent and crash-resilient: a re-run mints the same ids, overwrites the
   same targets, and re-deletes already-gone sources. *)
let folder_id rel = if rel = "" then Folder.root_id else Folder.hash_name rel

let is_hex16 s =
  String.length s = 16
  && String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       s

(* First path segment already looks like an inode id (reserved, or a dual-hash),
   i.e. the object is a folder marker or an already-migrated key — skip it so a
   re-run doesn't re-migrate its own output. *)
let migrated_segment seg =
  seg = Folder.root_id || seg = Folder.trash_id
  ||
    match String.split_on_char '-' seg with
    | [a; b] -> is_hex16 a && is_hex16 b
    | _ -> false

let first_segment s =
  match String.index_opt s '/' with Some i -> String.sub s 0 i | None -> s

let add_name json leaf =
  match json with
    | `Assoc fields ->
        `Assoc (("name", `String leaf) :: List.remove_assoc "name" fields)
    | j -> j

let reencode json = Yojson.Basic.to_string json

let with_name data leaf =
  reencode (add_name (Yojson.Basic.from_string data) leaf)

let migrate_backend ~dom_prefix ~ver_prefix ~jour_prefix ~cursor_key
    (bc : Conf_parsing.backend_config) =
  let (module B : Backend.S) =
    Backend.make ~backend_type:bc.backend_type ~get_field:(fun k ->
        List.assoc_opt k bc.fields)
  in
  let marked : (string, unit) Hashtbl.t = Hashtbl.create 256 in
  (* Write a folder marker (and its ancestors') under the parent's namespace. *)
  let rec ensure_marker rel =
    if rel = "" || Hashtbl.mem marked rel then Lwt.return_unit
    else begin
      Hashtbl.replace marked rel ();
      let* () = ensure_marker (parent rel) in
      let bkey =
        dom_prefix
        ^ Folder.child_key
            ~folder_id:(folder_id (parent rel))
            (Filename.basename rel)
      in
      let marker =
        Folder.marker_to_string
          { Folder.name = Filename.basename rel; id = folder_id rel }
      in
      B.put ~key:bkey ~data:marker ()
    end
  in
  let strip prefix key =
    String.sub key (String.length prefix)
      (String.length key - String.length prefix)
  in
  let* manifests = B.list_all ~prefix:dom_prefix () in
  let* () =
    Lwt_list.iter_s
      (fun (e : Backend.file_entry) ->
        let enc = strip dom_prefix e.key in
        if enc = "" || migrated_segment (first_segment enc) then Lwt.return_unit
        else if enc.[String.length enc - 1] = '/' then (
          (* old empty-dir marker -> folder marker; drop the old object *)
          let rel = decode (String.sub enc 0 (String.length enc - 1)) in
          let* () = ensure_marker rel in
          B.delete ~key:e.key ())
        else (
          let rel = decode enc in
          let leaf = Filename.basename rel in
          let* () = ensure_marker (parent rel) in
          let fid = folder_id (parent rel) in
          let* data = B.get ~key:e.key () in
          let newkey = dom_prefix ^ Folder.child_key ~folder_id:fid leaf in
          let* () = B.put ~key:newkey ~data:(with_name data leaf) () in
          B.delete ~key:e.key ()))
      manifests
  in
  (* Clean slate for mutable state: drop all versions, journal entries and the
     cursor. Chunks orphaned by dropped versions are reclaimed by the next
     [expire]. *)
  let delete_under prefix =
    let* objs = B.list_all ~prefix () in
    Lwt_list.iter_s
      (fun (e : Backend.file_entry) -> B.delete ~key:e.key ())
      objs
  in
  let* () = delete_under ver_prefix in
  let* () = delete_under jour_prefix in
  let* () =
    Lwt.catch (fun () -> B.delete ~key:cursor_key ()) (fun _ -> Lwt.return_unit)
  in
  Printf.printf "migrated backend %s\n%!" bc.Conf_parsing.name;
  Lwt.return_unit

let () =
  let config = Sys.argv.(1) in
  let domain = if Array.length Sys.argv > 2 then Some Sys.argv.(2) else None in
  let cfg = Conf_parsing.load config in
  Tls_conf.apply cfg.Conf_parsing.tls;
  let d = Conf_parsing.pick_domain ?domain cfg in
  let dom_prefix = Conf_parsing.domain_prefix d in
  let ver_prefix = Conf_parsing.versions_prefix d in
  let jour_prefix = Conf_parsing.journal_prefix d in
  let cursor_key = Conf_parsing.cursor_key d in
  Lwt_main.run
    (Lwt_list.iter_s
       (migrate_backend ~dom_prefix ~ver_prefix ~jour_prefix ~cursor_key)
       d.Conf_parsing.backends)
