open Tsync_core
open Tsync_store
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

(* uplink-governor §8: a metadata read of the domain cursor exists on every
   written store and costs almost nothing. *)
let probe d (store : Store.t) = ignore (store.head_opt (Key.cursor d))

(* 05 §3.2: parsing registered the type, so the driver is linked. *)
let create_store config d (b : Config.backend) =
  let admission =
    match b.link with
      | None -> Uplink.none
      | Some link ->
          Uplink.link link
            (Config.uplink_settings (Config.link_settings config link))
  in
  let store =
    (Option.get (Driver.find b.btype)).create ~domain:d ~admission ~name:b.bname
      b.fields
  in
  Uplink.attach admission ~store:b.bname
    ~probe:(fun () -> probe d store)
    ~health:store.health;
  store

let knowledge d =
  {
    Composite.is_index = (fun k -> Key.leaf k = ".tsync-index");
    is_journal =
      (fun k -> Key.under (Key.journal d) k || Key.equal k (Key.cursor d));
  }

(* 05 §3.2: one store client per backend, shared by every layer above it;
   deferred logs are resumed only by the owner. *)
(* 08 §2.1: the tree is the frontend's, whichever process owns the domain. *)
let pulled (dom : Config.domain) =
  List.find_map
    (fun (f : Config.frontend) ->
      Option.bind (Frontend.find f.ftype) (fun r -> r.Frontend.pulled))
    dom.frontends

let build ?(owner = true) ?(poke = ignore) ?cache_root ?data_dir
    (config : Config.t) (dom : Config.domain) =
  let lazy_tree = pulled dom <> None in
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
  let composite =
    Composite.create ~domain:d ~data_dir ~owner ~poke ~knowledge:(knowledge d)
      (List.map snd members)
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

(* 05 §3.1 reading_from: reads go to the member, writes still through the
   composite, so deferred targets still fill. *)
let reading_from t name =
  match
    List.find_opt
      (fun (m : Composite.member) -> m.name = name)
      (Composite.members t.composite)
  with
    | None ->
        Fail.raise_ Fail.Invalid "%s has no member named %s"
          (Domain_name.to_string t.name)
          name
    | Some m ->
        let s = m.store in
        {
          (Composite.store t.composite) with
          get_opt = s.get_opt;
          get_range = s.get_range;
          head_opt = s.head_opt;
          list_prefix = s.list_prefix;
          watch = s.watch;
          get_many = s.get_many;
          list_many = s.list_many;
          health = s.health;
        }

let context ?reading_from:source ?reading_at_most t :
    (module Tsync_remote.Context.S) =
  let store =
    match source with
      | Some name -> reading_from t name
      | None -> Composite.store t.composite
  in
  let max_downloads =
    match reading_at_most with
      | Some n when n < 1 -> Fail.raise_ Fail.Invalid "-j needs at least 1"
      | Some n -> n
      | None -> t.config.max_downloads
  in
  (module struct
    let domain = t.name
    let store = store
    let composite = t.composite
    let versioning = t.domain.versioning
    let chunk_size_config = t.domain.chunk_size
    let max_downloads = max_downloads
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
          | Some r -> (
              match acc with
                | Some (a : Fs.space) when a.available <= r.available -> acc
                | _ -> Some r)
          | None -> acc))
    None t.members
