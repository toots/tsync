(** Which manifest describes one file right now, and how to replace it.

    The mirror keyed one file at a time: what the store has published for it,
    what this client has staged over that, and the writing of either. The tree
    it all sits in -- listings, directories, renames -- is {!Checkout}, which is
    built on this. *)

open Manifest

module type S = sig
  type 'a io

  val root : unit -> string
  val path : Logical_key.t -> string
  val ensure_parent : Logical_key.t -> unit io
  val published : Logical_key.t -> Manifest.t option io
  val write : Logical_key.t -> Manifest.t -> unit io
  val delete : Logical_key.t -> unit io

  val current :
    Logical_key.t ->
    [ `Staged of Staged_manifest.staged * Manifest.t option
    | `Published of Manifest.t ]
    option
    io

  val forget : Logical_key.t -> unit
  val memo_size : unit -> int
end

module type OVER = sig
  type 'a io

  val ensure_dirs : string -> string -> unit io

  module Make (C : Conf.S with type 'a io = 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (F : Cache_layout.FS with type 'a io := 'a Io.t)
    (Sm : Staged_manifest.OVER with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  let dir ~cache_root domain_name =
    Cache_layout.manifests_dir ~cache_root domain_name

  (* A name marker goes inside each escaped component. *)
  let ensure_dirs root rel =
    let components =
      String.split_on_char '/' rel |> List.filter (fun c -> c <> "")
    in
    let* () = F.mkdir_p root in
    let rec go dir = function
      | [] -> return_unit
      | c :: rest ->
          let enc = Stored_key.escape c in
          let dir = Filename.concat dir enc in
          let* () = F.mkdir_p dir in
          let* () =
            if Stored_key.is_escaped enc then
              F.record_dir_name (Filename.concat dir Stored_key.dir_name_leaf) c
            else return_unit
          in
          go dir rest
    in
    go root components

  (* One table per domain however many places name it: two memos over one manifest
     tree would let a write through either go unseen by the other, which is a
     stale manifest served as current. *)
  let memo_capacity = 1024

  type memo_entry = { ino : int; size : int; mtime : float; manifest : t }

  type memos = {
    table : (string, memo_entry) Hashtbl.t;
    order : string Queue.t;
  }

  let memos : (string, memos) Hashtbl.t = Hashtbl.create 4

  let memos_for domain =
    match Hashtbl.find_opt memos domain with
      | Some m -> m
      | None ->
          let m = { table = Hashtbl.create 256; order = Queue.create () } in
          Hashtbl.replace memos domain m;
          m

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Sm = Sm.Make (C)

    let memo_of = memos_for (C.cache_root ^ "\000" ^ C.domain_name)
    let memo = memo_of.table
    let memo_order = memo_of.order
    let root () = dir ~cache_root:C.cache_root C.domain_name

    let path key =
      Cache_layout.manifest_path ~cache_root:C.cache_root
        ~domain_name:C.domain_name key

    let rel_of = Logical_key.path

    (* A memoised manifest holds the mapping it was read through, so the table
       bounds live mappings rather than merely bytes: an import reads one sidecar
       per file, and unbounded that is one mapping per file held for the life of
       the process — 19,261 of them, 75 MB of pinned page cache, in the run that
       found this.

       Eviction is by insertion rather than by use, which costs nothing worth
       measuring here: the walks that fill it touch each key once, and a dropped
       entry is a re-read of a page the kernel still has. *)
    let forget key = Hashtbl.remove memo (Logical_key.to_string key)

    let memoize key entry =
      let key = Logical_key.to_string key in
      Hashtbl.replace memo key entry;
      Queue.add key memo_order;
      while Queue.length memo_order > memo_capacity do
        Hashtbl.remove memo (Queue.pop memo_order)
      done

    let memo_size () = Hashtbl.length memo

    let published key =
      let p = path key in
      let* st = F.stat_opt p in
      match st with
        | None ->
            forget key;
            Io.return None
        | Some st -> (
            let ino = st.Unix.st_ino
            and size = st.Unix.st_size
            and mtime = st.Unix.st_mtime in
            match Hashtbl.find_opt memo (Logical_key.to_string key) with
              | Some e when e.ino = ino && e.size = size && e.mtime = mtime ->
                  return_some e.manifest
              | _ -> (
                  match of_file p with
                    | manifest ->
                        memoize key { ino; size; mtime; manifest };
                        return_some manifest
                    | exception _ -> Io.return None))

    let ensure_parent key =
      ensure_dirs (root ()) (rel_of (Logical_key.parent key))

    (* Sole writer of a manifest body in the cache, and it stamps the name from
       the key, so a mirror manifest always records the name it is filed under. *)
    let write key manifest =
      forget key;
      let* () = ensure_parent key in
      let bytes = body ~name:(Logical_key.leaf key) manifest in
      F.atomic_write_at (path key) ~size:(Bigstring.length bytes) (fun put ->
          put ~offset:0 bytes)

    let delete key =
      forget key;
      F.unlink_quiet (path key)

    (* The single resolution point: no caller decides this itself. *)
    let current key =
      let* st = Sm.read_edits key in
      match st with
        | Some st ->
            let+ published = published key in
            Some (`Staged (st, published))
        | None -> (
            let+ m = published key in
            match m with Some m -> Some (`Published m) | None -> None)
  end
end
