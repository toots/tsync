(** The batched read a store may have of its own, already resolved: which
    drivers have one and how wide the fan-out is are settled where the stores
    are built, not here. *)
module type BATCHED = sig
  type 'a io
  type pool

  module Make (_ : Backend.S with type 'a io := 'a io) : sig
    val get_many :
      ?slots:pool ->
      entries:Backend.file_entry list ->
      unit ->
      (Stored_key.t * Bigstring.t option) list io
  end
end

(** One folder as {!S.list_many} answers it. *)
type listed_folder = {
  folder_id : string;
  listed : Backend.file_entry list;
  bodies : (Stored_key.t * string option) list;
}

module type S = sig
  type 'a io
  type pool

  val put_manifest : key:Logical_key.t -> data:Bigstring.t -> unit io

  val get_manifest_state :
    key:Logical_key.t -> [ `Body of string | `Absent | `Unresolved ] io

  val head_manifest : key:Logical_key.t -> Backend.file_entry option io
  val delete_manifest : key:Logical_key.t -> unit io
  val copy_manifest : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io
  val ensure_folder_id : Logical_key.t -> string io

  val claim_folder :
    ?id:string -> Logical_key.t -> [ `Held | `Taken of string ] io

  val ensure_claimed : Logical_key.t -> unit io
  val put_folder_marker : key:Logical_key.t -> unit io
  val put_anchor : folder_id:string -> parent:string -> name:string -> unit io
  val get_anchor : folder_id:string -> Folder.anchor option io

  val placed :
    folder_id:string ->
    at:Folder.anchor ->
    [ `Here | `Elsewhere of Folder.anchor | `Unanchored ] io

  val marker_id_at : bkey:Stored_key.t -> string option io

  val filed :
    bkey:Stored_key.t ->
    Folder.marker ->
    [ `Here | `Elsewhere of Folder.anchor ] io

  val list_namespace : folder_id:string -> Backend.file_entry list io
  val get_object : bkey:Stored_key.t -> string io
  val get_object_opt : bkey:Stored_key.t -> string option io

  val get_objects :
    ?slots:pool ->
    entries:Backend.file_entry list ->
    unit ->
    (Stored_key.t * string option) list io

  (** Many folders' children in one request, where the store has a way to ask
      for them; a folder left out of the answer is the caller's to ask for
      singly. [None] from a store with none. *)
  val list_many :
    (folder_ids:string list -> unit -> listed_folder list io) option

  val put_raw : bkey:Stored_key.t -> data:string -> unit io
  val delete_raw : bkey:Stored_key.t -> bool io
end

module type OVER = sig
  type 'a io
  type pool

  module Make
      (C : Conf.S with type 'a io = 'a io)
      (L : Layout.S with type 'a io := 'a io) :
    S with type 'a io := 'a io and type pool = pool
end

module type INODE = sig
  type 'a io
  type pool

  module Make (_ : Conf.S with type 'a io = 'a io) :
    S with type 'a io := 'a io and type pool = pool
end

module Over
    (Io : Io.S)
    (Folder_ids : Folder_ids.S with type 'a io := 'a Io.t)
    (Batched : BATCHED with type 'a io := 'a Io.t) =
struct
  type pool = Batched.pool

  open Io_syntax.Make (Io)

  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (L : Layout.S with type 'a io := 'a Io.t) =
  struct
    type pool = Batched.pool

    module B = (val C.store : C.Store)
    module Bb = Batched.Make (B)
    module J = Journal.Make (C)
    module Lk = Logical_key.Make (C)

    let anchor_key folder_id =
      Stored_key.anchor_key ~prefix:C.domain_prefix ~folder_id

    let put_anchor ~folder_id ~parent ~name =
      B.put ~key:(anchor_key folder_id)
        ~data:(Bigstring.of_string (Folder.anchor_to_string { parent; name }))
        ()

    let get_anchor ~folder_id =
      let+ body = B.get_opt ~key:(anchor_key folder_id) () in
      Option.bind body (fun b ->
          Folder.anchor_of_string (Bigstring.to_string b))

    let placed ~folder_id ~(at : Folder.anchor) =
      let+ anchor = get_anchor ~folder_id in
      match anchor with
        | Some a when a = at -> `Here
        | Some a -> `Elsewhere a
        | None -> `Unanchored

    (* A folder with no anchor was written before anchors were, and is taken at
       its marker's word. *)
    let filed ~bkey (m : Folder.marker) =
      let+ placement =
        placed ~folder_id:m.Folder.id
          ~at:
            {
              Folder.parent = Stored_key.parent_folder_id bkey;
              name = m.Folder.name;
            }
      in
      match placement with
        | `Elsewhere a -> `Elsewhere a
        | `Here | `Unanchored -> `Here

    let marker_id_at ~bkey =
      let+ body = B.get_opt ~key:bkey () in
      Option.bind body (fun b ->
          Option.map
            (fun (m : Folder.marker) -> m.Folder.id)
            (Folder.marker_of_string (Bigstring.to_string b)))

    let unresolved what key =
      Io.fail
        (Invalid_argument
           (Printf.sprintf "%s: no %s for %s" C.domain_name what
              (Logical_key.to_string key)))

    (* A store that cannot arbitrate falls back to minting locally, said once
       because it is a real weakening: two clients creating one directory can
       then still strand each other. *)
    let warned_unarbitrated = ref false

    (* The marker {i is} the claim: two clients that have not yet seen each
       other both put one under the same key, and only the first lands. The
       winner anchors the folder it brought into existence; a loser leaves that
       to it. *)
    let claim_name ~key ~id =
      let* bkey = L.folder_marker_key key in
      let* parent = L.folder_id (Logical_key.parent key) in
      match (bkey, parent) with
        | None, _ | _, None -> unresolved "folder marker key" key
        | Some bkey, Some parent ->
            let name = Logical_key.leaf key in
            let candidate =
              Bigstring.of_string (Folder.marker_to_string { Folder.name; id })
            in
            let* held =
              Io.catch
                (fun () -> B.put_if_absent ~key:bkey ~data:candidate ())
                (fun exn ->
                  if not !warned_unarbitrated then begin
                    warned_unarbitrated := true;
                    Log.warn
                      "%s: this store cannot claim a name (%s); folder ids are \
                       minted locally and concurrent creation of one directory \
                       can strand files"
                      C.domain_name (Printexc.to_string exn)
                  end;
                  Io.return candidate)
            in
            let winner =
              Option.fold ~none:id
                ~some:(fun (m : Folder.marker) -> m.Folder.id)
                (Folder.marker_of_string (Bigstring.to_string held))
            in
            if winner = id then
              let+ () = put_anchor ~folder_id:id ~parent ~name in
              `Held
            else Io.return (`Taken winner)

    (* A folder's id is claimed from the store rather than chosen here, so every
       client puts its children under the id the store accepted. Still
       local-first: a folder already resolved costs no round trip. The parent is
       claimed first, so the key a claim names is already the agreed one. *)
    let rec ensure_folder_id key =
      let* known = L.folder_id key in
      match known with
        | Some id -> Io.return id
        | None -> (
            let* (_ : string) = ensure_folder_id (Logical_key.parent key) in
            let candidate = J.folder_id () in
            let* claimed = claim_name ~key ~id:candidate in
            let id =
              match claimed with `Held -> candidate | `Taken other -> other
            in
            let+ written =
              Folder_ids.write ~cache_root:C.cache_root
                ~domain_name:C.domain_name key
                { Folder.name = Logical_key.leaf key; id }
            in
            match written with `Written -> id | `Held held -> held)

    (* A marker already naming the folder is the common case and costs a read;
       only a name the store does not file yet is claimed, ancestors first, so
       a peer adopting top-down finds every level. An id-less folder takes
       whichever id the store holds, having none a reference could name.

       ponytail: one read per publish into a folder, a per-process set of names
       seen held if uploads into one folder ever dominate. *)
    let rec claim_folder ?id key =
      if Logical_key.is_root key then Io.return `Held
      else
        let* known =
          match id with Some id -> return_some id | None -> L.folder_id key
        in
        match known with
          | None -> (
              let* gone =
                Folder_ids.lookup_id_removed ~cache_root:C.cache_root
                  ~domain_name:C.domain_name key
              in
              match gone with
                (* Moved or removed here while this was owed: naming it again
                   would bring back a folder that is gone. A folder that moved
                   is published where it went by its own ops, and the layout
                   files what is written under its old path by its id. *)
                | Some id -> (
                    let* moved =
                      Folder_ids.key_of_id ~cache_root:C.cache_root
                        ~domain_name:C.domain_name ~root:Lk.root id
                    in
                    match moved with
                      | Some _ -> Io.return `Held
                      | None ->
                          Io.fail
                            (Retry.failed ~kind:Retry.Transient ~op:"claim"
                               (Logical_key.to_string key
                              ^ ": removed here since")))
                | None ->
                    let* () = claim_parent key in
                    let+ (_ : string) = ensure_folder_id key in
                    `Held)
          | Some id -> (
              let* bkey = L.folder_marker_key key in
              match bkey with
                (* No folder tree to file it in. *)
                | None -> Io.return `Held
                | Some bkey -> (
                    let* there = marker_id_at ~bkey in
                    match there with
                      | Some held when held = id -> Io.return `Held
                      | Some other -> Io.return (`Taken other)
                      | None ->
                          let* () = claim_parent key in
                          claim_name ~key ~id))

    (* A taken name is settled by that folder's own queued creation, which
       moves it aside, so what waits on it is retried rather than failing. *)
    and ensure_claimed key =
      let* claimed = claim_folder key in
      match claimed with
        | `Held -> Io.return ()
        | `Taken other ->
            Io.fail
              (Retry.failed ~kind:Retry.Transient ~op:"claim"
                 (Printf.sprintf "%s: the store files another folder (%s) there"
                    (Logical_key.to_string key)
                    other))

    and claim_parent key = ensure_claimed (Logical_key.parent key)

    (* Only a caller entitled to bring a folder into existence: the marker a
       claim persists re-creates the local directory the key names. *)
    let ensure_manifest_key key =
      let* () = claim_parent key in
      let* bk = L.manifest_key key in
      match bk with
        | Some bk -> Io.return bk
        | None -> unresolved "manifest key" key

    (* Publishing may bring the folder into existence; every other operation
       resolves what is already there and treats an unknown folder as absent. *)
    let put_manifest ~key ~data =
      let* bk = ensure_manifest_key key in
      B.put ~key:bk ~data ()

    let get_manifest_state ~key =
      let* bk = L.manifest_key key in
      match bk with
        | None -> Io.return `Unresolved
        | Some bk -> (
            let+ body = B.get_opt ~key:bk () in
            match body with
              | None -> `Absent
              | Some body -> `Body (Bigstring.to_string body))

    let head_manifest ~key =
      let* bk = L.manifest_key key in
      match bk with None -> Io.return None | Some bk -> B.head_opt ~key:bk ()

    let delete_manifest ~key =
      let* bk = L.manifest_key key in
      match bk with
        | None -> Io.return ()
        | Some bk ->
            let+ (_ : bool) = B.delete ~key:bk () in
            ()

    (* The destination may be brought into existence; the source has to be there
       already or there is nothing to move. *)
    let copy_manifest ~src_key ~dst_key =
      let* src = L.manifest_key src_key in
      match src with
        | None -> Io.return ()
        | Some src ->
            let* dst = ensure_manifest_key dst_key in
            let* () = B.copy ~src_key:src ~dst_key:dst () in
            let+ (_ : bool) = B.delete ~key:src () in
            ()

    (* The anchor first: from then on any other marker naming this folder is
       stale, whether or not the delete that should remove it ever lands. Both
       ids are ensured, the parent's because a marker must be filed under a
       namespace even on a client that has not learned the parent. *)
    let put_folder_marker ~key =
      if Logical_key.is_root key then Io.return ()
      else
        let* parent = ensure_folder_id (Logical_key.parent key) in
        let* id = ensure_folder_id key in
        let* bkey = L.folder_marker_key key in
        match bkey with
          | None -> Io.return ()
          | Some bkey ->
              let name = Logical_key.leaf key in
              let* () = put_anchor ~folder_id:id ~parent ~name in
              B.put ~key:bkey
                ~data:
                  (Bigstring.of_string
                     (Folder.marker_to_string { Folder.name; id }))
                ()

    (* Direct children (file manifests and folder markers) of a folder namespace,
       and a raw object fetch — used by resync to walk the inode tree by id. *)
    let list_namespace ~folder_id =
      B.list_prefix
        ~prefix:
          (Stored_key.to_string
             (Stored_key.namespace ~prefix:C.domain_prefix ~folder_id))
        ()

    let get_object ~bkey =
      let+ body = B.get ~key:bkey () in
      Bigstring.to_string body

    let get_object_opt ~bkey =
      let+ body = B.get_opt ~key:bkey () in
      Option.map Bigstring.to_string body

    let get_objects ?slots ~entries () =
      let+ answered = Bb.get_many ?slots ~entries () in
      List.map
        (fun (key, body) -> (key, Option.map Bigstring.to_string body))
        answered

    let namespace_of folder_id =
      Stored_key.to_string
        (Stored_key.namespace ~prefix:C.domain_prefix ~folder_id)

    let list_many =
      Option.map
        (fun native ~folder_ids () ->
          let ids = Hashtbl.create (List.length folder_ids) in
          List.iter
            (fun id -> Hashtbl.replace ids (namespace_of id) id)
            folder_ids;
          let+ answered =
            native ~prefixes:(List.map namespace_of folder_ids) ()
          in
          List.filter_map
            (fun (prefix, (c : Backend.children)) ->
              Option.map
                (fun folder_id ->
                  {
                    folder_id;
                    listed = c.Backend.listed;
                    bodies =
                      List.map
                        (fun (key, body) ->
                          (key, Option.map Bigstring.to_string body))
                        c.Backend.bodies;
                  })
                (Hashtbl.find_opt ids prefix))
            answered)
        B.list_many

    let delete_raw ~bkey = B.delete ~key:bkey ()

    let put_raw ~bkey ~data =
      B.put ~key:bkey ~data:(Bigstring.of_string data) ()
  end
end
