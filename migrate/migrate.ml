(* One-off, unchecked migration from the ORIGINAL real-path key layout
   (manifests/<percent-encoded-realpath>, body without a [name] field) to the
   inode layout (manifests/<folder_id>/<hash(leaf)> plus folder markers). Run
   once per domain, against a BACKUP first. Not built by the default target.

   Usage: migrate <config.json> [domain]

   Design for safety — the tool must be restartable after any failure:

   - Idempotent ids: a folder's id is derived from its path, so every run (and
     every backend of the domain) maps a folder to the same id. Re-running mints
     no new ids and overwrites the same targets.
   - Body-based classification: an object is already-migrated iff its body is a
     folder marker or a manifest that already carries a [name]. This never
     misclassifies a real old file by the *shape* of its key (e.g. a file whose
     name happens to look like a hashed id), which a key-pattern check would.
   - Put-before-delete: a manifest's new object is written before its old one is
     removed, so a crash in between leaves both — the re-run re-migrates the old
     (idempotent) and skips the new.
   - Per-object isolation: a failing object is logged and skipped, not fatal, so
     one bad object can't block the whole domain; the run exits non-zero if any
     object failed, and a re-run retries exactly those.

   Assumes the backend is already up to date (no unapplied journal): the journal
   and cursor are simply dropped. Versions and any trash are dropped too — the
   migration lands a clean slate, so clients re-sync in full afterwards. *)

open Lwt.Syntax

(* Reverse the retired per-component percent-encoding of old real-path keys. *)
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

(* Deterministic, path-derived folder id (128-bit) — see the header note on
   idempotency. Opaque handle; format need not match the daemon's random ids. *)
let folder_id rel = if rel = "" then Folder.root_id else Folder.hash_name rel

(* An object is already in the new layout when its body is a folder marker or a
   manifest that already carries a [name]. Old manifests have neither; an empty
   body (an old empty-dir marker) is not migrated data. *)
type kind = Marker | Migrated | Old | Not_data

let classify data =
  match Yojson.Basic.from_string data with
    | `Assoc fields ->
        if List.assoc_opt "dir" fields = Some (`Bool true) then Marker
        else if List.mem_assoc "name" fields then Migrated
        else Old
    | _ -> Not_data
    | exception _ -> Not_data

(* Rewrite an old manifest body into the new format: inject the leaf [name] and
   bump the format version, preserving every other field (chunks, symlink, …). *)
let migrate_body data leaf =
  match Yojson.Basic.from_string data with
    | `Assoc fields ->
        let fields =
          fields |> List.remove_assoc "name" |> List.remove_assoc "v"
        in
        Yojson.Basic.to_string
          (`Assoc
             (("v", `Int Manifest.current_version)
             :: ("name", `String leaf)
             :: fields))
    | j -> Yojson.Basic.to_string j

let strip prefix key =
  String.sub key (String.length prefix)
    (String.length key - String.length prefix)

let chop_slash s =
  if String.ends_with ~suffix:"/" s then String.sub s 0 (String.length s - 1)
  else s

let migrate_backend ~dom_prefix ~ver_prefix ~jour_prefix ~trash_prefix
    ~cursor_key (bc : Conf_parsing.backend_config) =
  let (module B : Backend.S) =
    Backend.make ~backend_type:bc.backend_type ~get_field:(fun k ->
        List.assoc_opt k bc.fields)
  in
  let migrated = ref 0 and skipped = ref 0 and failed = ref 0 in

  (* Write a folder marker (and its ancestors') under the parent's namespace.
     [marked] dedups within a run; across runs the put simply overwrites. *)
  let marked : (string, unit) Hashtbl.t = Hashtbl.create 256 in
  let rec ensure_marker rel =
    if rel = "" || Hashtbl.mem marked rel then Lwt.return_unit
    else (
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
      B.put ~key:bkey ~data:marker ())
  in

  (* Convert one old manifest: ensure its folder markers exist, write the new
     object, then remove the old one. *)
  let migrate_manifest ~old_key ~rel ~data =
    let leaf = Filename.basename rel in
    let* () = ensure_marker (parent rel) in
    let new_key =
      dom_prefix ^ Folder.child_key ~folder_id:(folder_id (parent rel)) leaf
    in
    let* () = B.put ~key:new_key ~data:(migrate_body data leaf) () in
    let* () = B.delete ~key:old_key () in
    incr migrated;
    Lwt.return_unit
  in

  let migrate_one (e : Backend.file_entry) =
    let enc = strip dom_prefix e.key in
    Lwt.catch
      (fun () ->
        if enc = "" then Lwt.return_unit (* the prefix marker itself *)
        else if String.ends_with ~suffix:"/" enc then (
          (* old empty-dir marker: becomes a folder marker; drop the old object.
             (Migrated keys never end in "/", so this is unambiguous.) *)
          let rel = decode (chop_slash enc) in
          let* () = ensure_marker rel in
          let* () = B.delete ~key:e.key () in
          incr migrated;
          Lwt.return_unit)
        else
          let* data = B.get ~key:e.key () in
          match classify data with
            | Marker | Migrated | Not_data ->
                (* already-migrated marker/manifest, or an empty/garbage body
                   (e.g. trash markers, cleared wholesale below) *)
                incr skipped;
                Lwt.return_unit
            | Old -> migrate_manifest ~old_key:e.key ~rel:(decode enc) ~data)
      (fun exn ->
        incr failed;
        Printf.eprintf "  FAILED %s: %s\n%!" e.key (Printexc.to_string exn);
        Lwt.return_unit)
  in

  Printf.printf "backend %s: migrating manifests…\n%!" bc.Conf_parsing.name;
  let* manifests = B.list_all ~prefix:dom_prefix () in
  let* () = Lwt_list.iter_s migrate_one manifests in

  (* Clean slate: drop trash, versions, the journal and the cursor. Each delete
     tolerates an already-gone key, so this is safe to re-run. Chunks orphaned by
     dropped versions/trash are reclaimed by the next [expire]. *)
  let delete_under label prefix =
    let* objs = B.list_all ~prefix () in
    let* () =
      Lwt_list.iter_s
        (fun (e : Backend.file_entry) ->
          Lwt.catch
            (fun () -> B.delete ~key:e.key ())
            (fun exn ->
              incr failed;
              Printf.eprintf "  FAILED delete %s: %s\n%!" e.key
                (Printexc.to_string exn);
              Lwt.return_unit))
        objs
    in
    if objs <> [] then
      Printf.printf "backend %s: cleared %d %s object(s)\n%!"
        bc.Conf_parsing.name (List.length objs) label;
    Lwt.return_unit
  in
  let* () = delete_under "trash" (dom_prefix ^ trash_prefix) in
  let* () = delete_under "version" ver_prefix in
  let* () = delete_under "journal" jour_prefix in
  let* () =
    Lwt.catch (fun () -> B.delete ~key:cursor_key ()) (fun _ -> Lwt.return_unit)
  in
  Printf.printf "backend %s: done — %d migrated, %d skipped, %d failed\n%!"
    bc.Conf_parsing.name !migrated !skipped !failed;
  Lwt.return !failed

let () =
  if Array.length Sys.argv < 2 then (
    prerr_endline "usage: migrate <config.json> [domain]";
    exit 2);
  let config = Sys.argv.(1) in
  let domain = if Array.length Sys.argv > 2 then Some Sys.argv.(2) else None in
  let cfg = Conf_parsing.load config in
  Tls_conf.apply cfg.Conf_parsing.tls;
  let d = Conf_parsing.pick_domain ?domain cfg in
  let dom_prefix = Conf_parsing.domain_prefix d in
  let ver_prefix = Conf_parsing.versions_prefix d in
  let jour_prefix = Conf_parsing.journal_prefix d in
  let cursor_key = Conf_parsing.cursor_key d in
  let trash_prefix = Folder.trash_id ^ "/" in
  let failed =
    Lwt_main.run
      (Lwt_list.fold_left_s
         (fun acc bc ->
           let+ f =
             migrate_backend ~dom_prefix ~ver_prefix ~jour_prefix ~trash_prefix
               ~cursor_key bc
           in
           acc + f)
         0 d.Conf_parsing.backends)
  in
  if failed > 0 then (
    Printf.eprintf "\n%d object(s) failed — re-run to retry them.\n%!" failed;
    exit 1)
  else Printf.printf "\nmigration complete.\n%!"
