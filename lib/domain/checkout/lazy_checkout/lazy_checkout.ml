(* What this needs below it: the tree it stands in front of, the store it reads a
   folder from, and the two writers that record what came back. Prose for each
   member lives with the module that implements it. *)
module type TREE = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val rename : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io
    val create_dir : Logical_key.t -> unit io
    val delete_dir : Logical_key.t -> unit io

    val list_children :
      prefix:Logical_key.t -> unit -> (Checkout.listed list * string list) io

    val list_tree : prefix:Logical_key.t -> unit -> Checkout.listed list io
  end
end

module type PULL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val children : folder_id:string -> unit -> Inode_tree.entry list io
  end
end

module type FILING = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val record : parent:Logical_key.t -> Inode_tree.entry -> Logical_key.t io
  end
end

module type FOLDERS = sig
  type 'a io

  val lookup_id :
    cache_root:string -> domain_name:string -> Logical_key.t -> string option io
end

module type MANIFESTS = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val delete : Logical_key.t -> unit io
  end
end

(* A working copy of what has been looked at, rather than of the domain.

   Listing a folder reads it from the store and records it, so an entry the tree
   below does not hold means "not fetched yet" here, where under the tree this
   decorates the same absence means the domain does not have it -- which is why
   the two are implementations a caller picks between rather than a flag. *)
module Over
    (Io : Io.S)
    (Ck : TREE with type 'a io := 'a Io.t)
    (P : PULL with type 'a io := 'a Io.t)
    (Fl : FILING with type 'a io := 'a Io.t)
    (Fi : FOLDERS with type 'a io := 'a Io.t)
    (Mf : MANIFESTS with type 'a io := 'a Io.t) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x

  let rec iter_s f = function
    | [] -> Io.return ()
    | x :: rest -> Io.bind (f x) (fun () -> iter_s f rest)

  (* Sequential: the width would otherwise be the folder's child count, which is
     the store's to choose and not ours. *)
  let map_s f xs =
    let rec go acc = function
      | [] -> Io.return (List.rev acc)
      | x :: rest -> Io.bind (f x) (fun y -> go (y :: acc) rest)
    in
    go [] xs

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module T = Ck.Make (C)
    module Pull = P.Make (C)
    module Filing = Fl.Make (C)
    module Manifests = Mf.Make (C)
    module Lk = Logical_key.Make (C)

    let rename = T.rename
    let create_dir = T.create_dir
    let delete_dir = T.delete_dir
    let list_tree = T.list_tree

    let folder_id prefix =
      if Logical_key.equal prefix Lk.root then
        Io.return (Some Stored_key.root_id)
      else
        Fi.lookup_id ~cache_root:C.cache_root ~domain_name:C.domain_name prefix

    let record prefix entry =
      let+ filed = Filing.record ~parent:prefix entry in
      Logical_key.leaf filed

    (* Only the published half is dropped: a staged body is this client's own
       and is not the store's to retract. *)
    let prune prefix kept =
      let* files, dirs = T.list_children ~prefix () in
      let* () =
        iter_s
          (fun (e : Checkout.listed) ->
            let name = Logical_key.leaf e.Checkout.key in
            if List.mem name kept then Io.return ()
            else Manifests.delete e.Checkout.key)
          files
      in
      iter_s
        (fun name ->
          if List.mem name kept then Io.return ()
          else delete_dir (Logical_key.dir_in prefix name))
        dirs

    (* [`Fail] inside the pull rather than skipping: a listing that lost a child
       is not evidence the child is gone, and pruning on one would delete what it
       could not read. *)
    let pull prefix =
      let* id = folder_id prefix in
      match id with
        | None -> Io.return ()
        | Some folder_id ->
            let* entries = Pull.children ~folder_id () in
            let* kept = map_s (record prefix) entries in
            prune prefix kept

    let list_children ~prefix () =
      let* () = pull prefix in
      T.list_children ~prefix ()
  end
end
