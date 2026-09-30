open Tsync_core
open Tsync_store
open Tsync_remote
open Tsync_sync
open Tsync_config

type t = {
  config : Config.t;
  domain : Config.domain;
  name : Domain_name.t;
  composite : Composite.t;
  members : (Config.backend * Composite.member) list;
  lazy_tree : bool;
  cache_root : string;
  data_dir : string;
  poke : unit -> unit;
}

(* 05 §3.2: parsing registered the type, so the driver is linked. *)
let create_store config d (b : Config.backend) =
  let admission =
    match b.link with
      | None -> Uplink.none
      | Some link ->
          let s = Config.link_settings config link in
          Uplink.link link ~enabled:s.enabled ~max_rate:s.max_rate
  in
  (Option.get (Driver.find b.btype)).create ~domain:d ~admission ~name:b.bname
    b.fields

let knowledge d main =
  {
    Composite.chunk_names = Manifest.chunk_names;
    generation = (fun () -> Remote.read_generation main d);
    is_index = (fun k -> Key.leaf k = ".tsync-index");
    is_journal =
      (fun k -> Key.under (Key.journal d) k || Key.equal k (Key.cursor d));
  }

(* 05 §3.2: one store client per backend, shared by every layer above it;
   deferred logs are resumed only by the owner. *)
let build ?(owner = true) ?(poke = ignore) ?(lazy_tree = false) ?cache_root
    ?data_dir (config : Config.t) (dom : Config.domain) =
  let cache_root =
    match cache_root with Some c -> c | None -> Paths.cache_root ()
  in
  let data_dir =
    match data_dir with Some d -> d | None -> Paths.data_dir ()
  in
  let d = dom.name in
  let members =
    List.map
      (fun (b : Config.backend) ->
        ( b,
          {
            Composite.name = b.bname;
            role = b.role;
            store = create_store config d b;
          } ))
      dom.backends
  in
  let main =
    match
      List.find_opt (fun (_, (m : Composite.member)) -> m.role = Main) members
    with
      | Some (_, m) -> m.store
      | None -> (snd (List.hd members)).store
  in
  let composite =
    Composite.create ~domain:d ~data_dir ~owner ~poke
      ~knowledge:(knowledge d main) (List.map snd members)
  in
  {
    config;
    domain = dom;
    name = d;
    composite;
    members;
    lazy_tree;
    cache_root;
    data_dir;
    poke;
  }

let context t : (module Tsync_remote.Context.S) =
  (module struct
    let domain = t.name
    let store = Composite.store t.composite
    let composite = t.composite
    let versioning = t.domain.versioning
    let chunk_size_config = t.domain.chunk_size
    let max_downloads = t.config.max_downloads
    let max_chunk_buffers = t.config.max_chunk_buffers
  end)

let engine t =
  let module C = struct
    let domain = t.name
    let store = Composite.store t.composite
    let composite = t.composite
    let versioning = t.domain.versioning
    let chunk_size_config = t.domain.chunk_size
    let max_downloads = t.config.max_downloads
    let max_chunk_buffers = t.config.max_chunk_buffers
    let cache_root = t.cache_root
    let data_dir = t.data_dir
    let client_uuid = Tsync_checkout.Identity.client_uuid t.data_dir
    let client_name = t.config.client_name

    let cache_chunk_size =
      Option.value ~default:Tsync_checkout.Cache.default_cache_chunk_size
        t.domain.cache_chunk_size

    let max_cache = t.domain.max_cache
    let max_uploads = t.config.max_uploads
    let read_only = t.domain.read_only
    let symlinks = t.domain.symlinks
    let lazy_tree = t.lazy_tree
  end in
  (module Engine.Make (C) : Engine.S)

let store t = Composite.store t.composite

(* 05 §3.1: the disk-space record of the writable local member with the least
   available space. *)
let capacity t =
  List.fold_left
    (fun acc ((_ : Config.backend), (m : Composite.member)) ->
      if m.role = Read_only then acc
      else (
        match Option.bind m.store.local_path Fs.disk_space with
          | Some ((avail, _, _) as r) -> (
              match acc with
                | Some (a, _, _) when a <= avail -> acc
                | _ -> Some r)
          | None -> acc))
    None t.members
