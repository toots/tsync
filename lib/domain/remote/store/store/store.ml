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

module type S = sig
  type 'a io
  type pool

  val put_manifest : key:Logical_key.t -> data:Bigstring.t -> unit io

  val get_manifest_state :
    key:Logical_key.t -> [ `Body of string | `Absent | `Unresolved ] io

  val head_manifest : key:Logical_key.t -> Backend.file_entry option io
  val delete_manifest : key:Logical_key.t -> unit io
  val copy_manifest : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io
  val put_folder_marker : key:Logical_key.t -> unit io
  val list_namespace : folder_id:string -> Backend.file_entry list io
  val get_object : bkey:Stored_key.t -> string io

  val get_objects :
    ?slots:pool ->
    entries:Backend.file_entry list ->
    unit ->
    (Stored_key.t * string option) list io

  val put_raw : bkey:Stored_key.t -> data:string -> unit io
  val delete_raw : bkey:Stored_key.t -> unit io
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

module Over (Io : Io.S) (Batched : BATCHED with type 'a io := 'a Io.t) = struct
  type pool = Batched.pool

  open Io_syntax.Make (Io)

  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (L : Layout.S with type 'a io := 'a Io.t) =
  struct
    type pool = Batched.pool

    module B = (val C.store : C.Store)
    module Bb = Batched.Make (B)

    (* Publishing may bring the folder into existence; every other operation
       resolves what is already there and treats an unknown folder as absent. *)
    let put_manifest ~key ~data =
      let* bk = L.ensure_manifest_key key in
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
      match bk with None -> Io.return () | Some bk -> B.delete ~key:bk ()

    (* The destination may be brought into existence; the source has to be there
       already or there is nothing to move. *)
    let copy_manifest ~src_key ~dst_key =
      let* src = L.manifest_key src_key in
      match src with
        | None -> Io.return ()
        | Some src ->
            let* dst = L.ensure_manifest_key dst_key in
            let* () = B.copy ~src_key:src ~dst_key:dst () in
            B.delete ~key:src ()

    (* Records a directory under its parent's namespace so resync can rebuild the
       tree. No-op for layouts with no folder tree. *)
    let put_folder_marker ~key =
      let* m = L.ensure_folder_marker key in
      match m with
        | None -> Io.return ()
        | Some (bkey, data) ->
            B.put ~key:bkey ~data:(Bigstring.of_string data) ()

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

    let get_objects ?slots ~entries () =
      let+ answered = Bb.get_many ?slots ~entries () in
      List.map
        (fun (key, body) -> (key, Option.map Bigstring.to_string body))
        answered

    let delete_raw ~bkey = B.delete ~key:bkey ()

    let put_raw ~bkey ~data =
      B.put ~key:bkey ~data:(Bigstring.of_string data) ()
  end
end
