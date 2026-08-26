type status = Exported | Exported_symlink | Missing_data
type summary = { exported : int; missing : int }

(** Making the destination tree, and the one symlink an export may write. *)
module type FS = sig
  type 'a io

  val mkdir_p : string -> unit io
  val ensure_parent : string -> unit io
  val unlink_quiet : string -> unit io
end

module type SYSCALLS = sig
  type 'a io

  val symlink : ?to_dir:bool -> string -> string -> unit io
end

(** Walking the backend's folder tree, which is how a whole domain is reached
    from its root. *)
module type TREE = sig
  type 'a io
  type pool

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val fold_tree :
      ?on_unusable:Inode_tree.on_unusable ->
      ?refresh_index:bool ->
      ?on_index:(Stored_key.t -> unit) ->
      ?slots:pool ->
      folder_id:string ->
      key:Logical_key.t ->
      ('a -> Logical_key.t -> Inode_tree.entry -> 'a io) ->
      'a ->
      'a io
  end
end

(** What is already in the checkout, and what the staged half is holding. *)
module type CHECKOUT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val walk : unit -> string list io
  end
end

module type STAGED = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val exists : Logical_key.t -> bool io
  end
end

(** Putting a file's bytes somewhere, which is the export itself. Its own store
    is wired in where the modules are built, since nothing here names one. *)
module type CONTENT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val published : Logical_key.t -> Manifest.t option io
    val assemble_to : Logical_key.t -> dst_path:string -> unit io
  end
end

module Over
    (Io : Io.S)
    (Files : FS with type 'a io := 'a Io.t)
    (Syscalls : SYSCALLS with type 'a io := 'a Io.t)
    (Tree : TREE with type 'a io := 'a Io.t)
    (Checkout : CHECKOUT with type 'a io := 'a Io.t)
    (Staged : STAGED with type 'a io := 'a Io.t)
    (Content : CONTENT with type 'a io := 'a Io.t) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x

  let rec iter_s f = function
    | [] -> Io.return ()
    | x :: rest ->
        let* () = f x in
        iter_s f rest

  let rec map_s f = function
    | [] -> Io.return []
    | x :: rest ->
        let* y = f x in
        let+ ys = map_s f rest in
        y :: ys

  let rec filter_map_s f = function
    | [] -> Io.return []
    | x :: rest -> (
        let* y = f x in
        let+ ys = filter_map_s f rest in
        match y with Some y -> y :: ys | None -> ys)

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Lk = Logical_key.Make (C)
    module Tree = Tree.Make (C)
    module Mf = Checkout.Make (C)
    module Mfs = Staged.Make (C)
    module D = Content.Make (C)

    (* Assembling through the read path covers unsynced staged edits, a partially
       cached file and a never-cached one alike. Only symlinks are special, having
       no content. *)
    let export_file ~dst rel =
      let key = Lk.file rel in
      let dst_path = Filename.concat dst rel in
      let* () = Files.ensure_parent dst_path in
      let* manifest = D.published key in
      match Option.map (fun m -> (m, Manifest.symlink m)) manifest with
        | Some (_, Some target) ->
            let* () = Files.unlink_quiet dst_path in
            let+ () = Syscalls.symlink target dst_path in
            Exported_symlink
        | Some (_, None) ->
            let+ () = D.assemble_to key ~dst_path in
            Exported
        | None ->
            (* A staged file has no published manifest yet, but its content is
               local and readable. *)
            let* staged = Mfs.exists key in
            if not staged then Io.return Missing_data
            else
              let+ () = D.assemble_to key ~dst_path in
              Exported

    (* Errors are skipped rather than fatal: one unreadable object should cost its
       own file, not the whole export. *)
    let remote_rels () =
      Tree.fold_tree
        ~on_unusable:(`Skip (fun _ _ -> ()))
        ~folder_id:Stored_key.root_id ~key:Lk.root
        (fun acc key entry ->
          match entry.Inode_tree.body with
            (* Walked by backend key, which is hashed, so the body is the only
               thing that knows the name. *)
            | Inode_tree.File m ->
                Io.return
                  (Logical_key.path
                     (Logical_key.file_in key (Manifest.recorded_name m))
                  :: acc)
            | Inode_tree.Dir _ -> Io.return acc)
        []

    let run ?(on_plan = fun ~files:_ -> ()) ?(on_start = fun ~rel:_ -> ()) ~dst
        ~on_file () =
      let* remote_rels = remote_rels () in
      let* local_rels = Mf.walk () in
      let files = List.sort_uniq compare (remote_rels @ local_rels) in
      on_plan ~files:(List.length files);
      let* () = Files.mkdir_p dst in
      let+ statuses =
        map_s
          (fun rel ->
            on_start ~rel;
            let+ status = export_file ~dst rel in
            on_file ~rel status;
            status)
          files
      in
      {
        exported =
          List.length
            (List.filter
               (function Missing_data -> false | _ -> true)
               statuses);
        missing =
          List.length
            (List.filter
               (function Missing_data -> true | _ -> false)
               statuses);
      }
  end
end
