type entry = { path : string; latest : int64; versions : int }

(** The id naming a folder's own namespace, minted if this client has none. *)
module type FOLDER_IDS = sig
  type 'a io

  val ensure_id :
    cache_root:string -> domain_name:string -> Logical_key.t -> string io
end

module Over (Io : Io.S) (Folder_ids : FOLDER_IDS with type 'a io := 'a Io.t) =
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

  let rec fold_left_s f acc = function
    | [] -> Io.return acc
    | x :: rest ->
        let* acc = f acc x in
        fold_left_s f acc rest

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Lk = Logical_key.Make (C)
    module B = (val C.store : C.Store)

    let parse key = History.parse ~versions_prefix:C.versions_prefix key

    (* Version keys are hashed, so the real name is read out of the body a version
       kept rather than derived from the key. *)
    let recorded_name key fallback =
      Io.catch
        (fun () ->
          let+ data = B.get ~key () in
          match Manifest.of_string (Bigstring.to_string data) with
            | m -> Manifest.recorded_name m
            | exception _ -> fallback)
        (fun _ -> Io.return fallback)

    let live grouping =
      let+ head =
        B.head_opt
          ~key:(History.manifest_of ~domain_prefix:C.domain_prefix ~grouping)
          ()
      in
      head <> None

    let in_folder key =
      (* Versions of the files in a folder share the folder's id. *)
      let* fid =
        Folder_ids.ensure_id ~cache_root:C.cache_root ~domain_name:C.domain_name
          key
      in
      let* entries =
        B.list_prefix
          ~prefix:
            (Stored_key.to_string
               (History.folder_versions ~versions_prefix:C.versions_prefix
                  ~folder_id:fid))
          ()
      in
      let seen = Hashtbl.create 16 in
      filter_map_s
        (fun (e : Backend.file_entry) ->
          match parse e.Backend.key with
            | Some (hrel, _) when not (Hashtbl.mem seen hrel) ->
                Hashtbl.add seen hrel ();
                let* alive = live hrel in
                if alive then Io.return None
                else
                  let+ name = recorded_name e.Backend.key hrel in
                  Some name
            | _ -> Io.return None)
        entries

    let in_domain () =
      let latest = Hashtbl.create 64
      and count = Hashtbl.create 64
      and sample = Hashtbl.create 64 in
      let* entries = B.list_prefix ~prefix:C.versions_prefix () in
      List.iter
        (fun (e : Backend.file_entry) ->
          match parse e.Backend.key with
            | Some (rel, ts) ->
                let ts = Int64.of_string ts in
                let best =
                  Option.value ~default:0L (Hashtbl.find_opt latest rel)
                in
                if Int64.compare ts best > 0 then Hashtbl.replace latest rel ts;
                Hashtbl.replace sample rel e.Backend.key;
                Hashtbl.replace count rel
                  (1 + Option.value ~default:0 (Hashtbl.find_opt count rel))
            | None -> ())
        entries;
      Hashtbl.fold
        (fun rel ts acc ->
          let* acc = acc in
          let* alive = live rel in
          if alive then Io.return acc
          else
            let+ path = recorded_name (Hashtbl.find sample rel) rel in
            {
              path;
              latest = ts;
              versions = Option.value ~default:1 (Hashtbl.find_opt count rel);
            }
            :: acc)
        latest (Io.return [])
  end
end
