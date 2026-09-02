(** What the store keeps of a file after the live tree stopped pointing at it.

    A version is a copy of the manifest object as it stood before a write, filed
    under the same folder id the manifest itself uses — so versions survive a
    rename of the folder, and a file that is deleted outright leaves its
    versions behind under a key nothing live resolves. *)

(* [rel] is a folder-id/leaf-hash pair, used only as an opaque grouping key; the
   timestamp orders versions. *)
let parse ~versions_prefix key =
  let key = Stored_key.to_string key in
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

(* A grouping key is the manifest's own key with the domain root taken off, so
   versions share the manifest's identity — a stable folder id — and survive a
   folder rename. These and {!parse} are that one fact read each way. *)
let versions_of ~versions_prefix ~grouping =
  Stored_key.in_space ~prefix:versions_prefix (grouping ^ "/")

let manifest_of ~domain_prefix ~grouping =
  Stored_key.in_space ~prefix:domain_prefix grouping

let folder_versions ~versions_prefix ~folder_id =
  Stored_key.namespace ~prefix:versions_prefix ~folder_id

module type S = sig
  type 'a io

    val version_dir : key:Logical_key.t -> Stored_key.t option io

    val save_version : key:Logical_key.t -> unit io

  val list_versions : key:Logical_key.t -> Backend.file_entry list io
  val get_version : vkey:Stored_key.t -> string io

    val parse : Stored_key.t -> (string * string) option
end

module type OVER = sig
  type 'a io

  module Make
      (C : Conf.S with type 'a io = 'a io)
      (L : Layout.S with type 'a io := 'a io) : S with type 'a io := 'a io
end

module Over (Io : Io.S) = struct
  open Io_syntax.Make (Io)

  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (L : Layout.S with type 'a io := 'a Io.t) =
  struct
    module B = (val C.store : C.Store)

    let version_dir ~key =
      let+ bk = L.manifest_key key in
      Option.map
        (fun bk ->
          versions_of ~versions_prefix:C.versions_prefix
            ~grouping:(Stored_key.path_in ~prefix:C.domain_prefix bk))
        bk

    (* Snapshot the current manifest object under a fresh timestamped version key,
       when it exists on the backend. Best-effort: a lost snapshot must not wedge
       the write it precedes. *)
    let save_version ~key =
      let* bk = L.manifest_key key in
      match bk with
        | None -> Io.return ()
        | Some bk -> (
            let* head = B.head_opt ~key:bk () in
            match head with
              | None -> Io.return ()
              | Some _ -> (
                  let ts = Int64.of_float (Unix.gettimeofday () *. 1e9) in
                  let* dir = version_dir ~key in
                  match dir with
                    | None -> Io.return ()
                    | Some dir ->
                        Io.catch
                          (fun () ->
                            B.copy ~src_key:bk
                              ~dst_key:
                                (Stored_key.under dir (Int64.to_string ts))
                              ())
                          (fun exn ->
                            Log.warn "save_version %s: %s"
                              (Logical_key.to_string key)
                              (Printexc.to_string exn);
                            Io.return ())))

    let list_versions ~key =
      let* dir = version_dir ~key in
      match dir with
        | None -> Io.return []
        | Some dir -> B.list_prefix ~prefix:(Stored_key.to_string dir) ()

    let get_version ~vkey =
      let+ body = B.get ~key:vkey () in
      Bigstring.to_string body

    (* The other direction of the key {!version_dir} builds. *)
    let parse key = parse ~versions_prefix:C.versions_prefix key
  end
end
