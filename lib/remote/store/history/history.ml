(** What the store keeps of a file after the live tree stopped pointing at it.

    A version is a copy of the manifest object as it stood before a write, filed
    under the same folder id the manifest itself uses — so versions survive a
    rename of the folder, and a file that is deleted outright leaves its
    versions behind under a key nothing live resolves. *)

open Lwt.Syntax

(* [rel] is a folder-id/leaf-hash pair, used only as an opaque grouping key; the
   timestamp orders versions. *)
let parse ~versions_prefix key =
  let n = String.length versions_prefix in
  if String.length key <= n || String.sub key 0 n <> versions_prefix then None
  else (
    let rest = String.sub key n (String.length key - n) in
    match String.rindex_opt rest '/' with
      | Some i when i < String.length rest - 1 ->
          Some
            ( String.sub rest 0 i,
              String.sub rest (i + 1) (String.length rest - i - 1) )
      | _ -> None)

module Make (C : Conf.S) (L : Layout.S) = struct
  module B = (val C.store : Backend.S)

  (* [<versions>/<manifest-key-tail>/<ts>], so versions share the manifest's
     identity — a stable folder id — and survive a folder rename. *)
  let version_dir ~key =
    let+ bk = L.manifest_key key in
    Option.map
      (fun bk ->
        C.versions_prefix
        ^ Key.strip_prefix ~domain_prefix:C.domain_prefix bk
        ^ "/")
      bk

  (* Snapshot the current manifest object under a fresh timestamped version key,
     when it exists on the backend. Best-effort: a lost snapshot must not wedge
     the write it precedes. *)
  let save_version ~key =
    let* bk = L.manifest_key key in
    match bk with
      | None -> Lwt.return_unit
      | Some bk -> (
          let* head = B.head_opt ~key:bk () in
          match head with
            | None -> Lwt.return_unit
            | Some _ -> (
                let ts = Int64.of_float (Unix.gettimeofday () *. 1e9) in
                let* dir = version_dir ~key in
                match dir with
                  | None -> Lwt.return_unit
                  | Some dir ->
                      Lwt.catch
                        (fun () ->
                          B.copy ~src_key:bk
                            ~dst_key:(dir ^ Int64.to_string ts)
                            ())
                        (fun exn ->
                          Log.warn "save_version %s: %s"
                            (Logical_key.to_string key)
                            (Printexc.to_string exn);
                          Lwt.return_unit)))

  let list_versions ~key =
    let* dir = version_dir ~key in
    match dir with
      | None -> Lwt.return_nil
      | Some dir -> B.list_prefix ~prefix:dir ()

  let get_version ~vkey =
    let+ body = B.get ~key:vkey () in
    Bigstring.to_string body

  (* The other direction of the key {!version_dir} builds. *)
  let parse key = parse ~versions_prefix:C.versions_prefix key
end
