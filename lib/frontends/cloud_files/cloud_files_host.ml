open Tsync_core
open Tsync_owner
open Tsync_cloud_files_rules
module Domain = Tsync_domain.Domain

type t = {
  engine : (module Tsync_sync.Engine.S);
  root : string;
  handler : Handler.t;
  connection : Cf.connection;
  take : Take.t;
  apply : Apply.t;
}

exception Failed_with of Cf.status * exn

(* cloud-files §12 *)
let status_of_failure = function
  | Fail.E { kind = Absent; _ } -> `Not_in_sync
  | Fail.E { kind = Read_only | Denied; _ } -> `Access_denied
  | Fail.E { kind = Invalid; _ } -> `Invalid
  | Fail.E { kind = Unreachable | Link; _ } -> `Network_unavailable
  | _ -> `Unsuccessful

(* §8.1: the sync root itself carries no identity and stands for root. *)
let ref_of t (r : Cf.request) =
  if r.identity = "" && Win_path.same r.path t.root then Some "root"
  else Option.map (fun (i : Identity.t) -> i.ref_) (Identity.decode r.identity)

let rows t ref_ = Listing.rows t.handler ref_

let placeholder (row : Protocol.row) name : Cf.placeholder =
  let is_dir = row.kind = `Dir in
  {
    name;
    is_dir;
    size = (if is_dir then 0 else row.size);
    mtime = (if row.mtime > 0. then row.mtime else Unix.gettimeofday ());
    identity =
      Identity.encode
        {
          ref_ = row.ref_;
          content_id =
            (if is_dir then "" else Option.value ~default:"" row.content_id);
        };
    read_only = row.read_only;
  }

(* §9.1: the presented children the folder does not hold yet become
   placeholders, and the folder is marked populated. *)
let fetch_placeholders t (r : Cf.request) =
  match ref_of t r with
    | None -> Cf.transfer_placeholders t.connection r `Invalid []
    | Some ref_ -> (
        match Rt.run_sync (fun () -> rows t ref_) with
          | exception e ->
              Log.warn "cloud_files: listing %s: %s" r.path
                (Printexc.to_string e);
              Cf.transfer_placeholders t.connection r (status_of_failure e) []
          | rows ->
              let on_disk = Hashtbl.create 16 in
              (try
                 Array.iter
                   (fun n -> Hashtbl.replace on_disk n ())
                   (Sys.readdir r.path)
               with Sys_error _ -> ());
              let presented, others =
                Presentation.choose ~fold:Cf.upcase
                  ~on_disk:(Hashtbl.mem on_disk)
                  (List.filter_map
                     (fun (row : Protocol.row) ->
                       if row.kind = `Symlink then None else Some (row.name, row))
                     rows)
              in
              List.iter
                (fun ((row : Protocol.row), why) ->
                  Log.info "cloud_files: %s not shown: %s" row.name
                    (match why with
                      | `Unpresentable reason -> reason
                      | `Case_group shown -> "its case group shows " ^ shown))
                others;
              Cf.transfer_placeholders t.connection r `Success
                (List.filter_map
                   (fun (row, name) ->
                     if Hashtbl.mem on_disk name then None
                     else Some (placeholder row name))
                   presented);
              (* §9.1: a change that raced the listing is applied after it. *)
              Apply.schedule t.apply ref_)

(* §9.1: transfers start at a multiple of this and are a multiple of it long,
   except the one that ends at end of file. *)
let alignment = 4096
let piece = 1 lsl 20

(* §9.1: the version served is the placeholder's, held for the whole fetch; a
   content changed since answers not in sync, never new bytes under the old
   identity. *)
let fetch_data t (r : Cf.request) =
  let (module E : Tsync_sync.Engine.S) = t.engine in
  match Identity.decode r.identity with
    | None -> raise (Failed_with (`Invalid, Failure "a foreign placeholder"))
    | Some id -> (
        let held =
          try
            Rt.run_sync (fun () ->
                let path = Handler.path_of_ref t.handler id.ref_ in
                E.atomically (fun () ->
                    if (E.stat path).content_id = Some id.content_id then
                      Some (E.retain path)
                    else None))
          with e -> raise (Failed_with (status_of_failure e, e))
        in
        match held with
          | None ->
              raise
                (Failed_with
                   (`Not_in_sync, Failure "its content changed in the domain"))
          | Some h ->
              Fun.protect
                ~finally:(fun () -> Rt.run_sync (fun () -> E.release h))
                (fun () ->
                  let start = r.offset / alignment * alignment in
                  let stop =
                    min r.file_size
                      ((r.offset + r.length + alignment - 1)
                      / alignment * alignment)
                  in
                  let rec send off =
                    if off < stop then (
                      let len = min piece (stop - off) in
                      let bytes =
                        try Rt.run_sync (fun () -> E.read h ~off ~len)
                        with e -> raise (Failed_with (status_of_failure e, e))
                      in
                      let got = Bigstring.length bytes in
                      if got = 0 then
                        raise
                          (Failed_with
                             ( `Unsuccessful,
                               Failure "the content ended before its size" ));
                      Cf.transfer_data t.connection r `Success bytes ~offset:off
                        ~length:got;
                      send (off + got))
                  in
                  send start))

(* §12, the delete and rename column. *)
let mutation_status = function
  | Fail.E { kind = Absent; _ } -> `Success
  | Fail.E { kind = Exists; _ } -> `Collision
  | Fail.E { kind = Not_empty; _ } -> `Not_empty
  | Fail.E { kind = Read_only | Denied; _ } -> `Access_denied
  | Fail.E { kind = Invalid; _ } -> `Invalid
  | _ -> `Unsuccessful

(* §9.1: the provider's own changes follow the domain, which holds them. *)
let own (r : Cf.request) = r.process_id = Pid.self ()
let is_dir_flag = 1
let target_in_scope_flag = 4

exception Refused of Cf.status * string

let decoded identity = Option.bind identity (fun s -> Identity.decode s)

(* A folder of the sync root as the domain names it, by its placeholder. *)
let folder_ref t dir =
  if Win_path.same dir t.root then "root"
  else (
    match decoded (Cf.identity dir) with
      | Some id -> id.ref_
      | None ->
          raise (Refused (`Unsuccessful, dir ^ " is not in the domain yet")))

(* §7.3, §9.2: a folder holding what the user never saw cannot leave. *)
let check_all_presented t dir ref_ =
  let rows = Rt.run_sync (fun () -> rows t ref_) in
  let _, others =
    Presentation.choose ~fold:Cf.upcase
      ~on_disk:(fun _ -> false)
      (List.map (fun (row : Protocol.row) -> (row.name, row)) rows)
  in
  if
    others <> []
    || List.exists (fun (row : Protocol.row) -> row.kind = `Symlink) rows
  then raise (Refused (`Not_empty, dir ^ " holds items not shown here"))

(* §9.2: what leaves the sync root is made whole on disk first, folders
   populated by listing them, so the user keeps every byte. *)
let rec make_whole t path ~is_dir =
  if is_dir then (
    (match decoded (Cf.identity path) with
      | Some id -> check_all_presented t path id.ref_
      | None -> ());
    Array.iter
      (fun name ->
        let child = Filename.concat path name in
        make_whole t child ~is_dir:(Sys.is_directory child))
      (Sys.readdir path))
  else if Cf.identity path <> None then Cf.hydrate path

let delete t (r : Cf.request) =
  let (module E : Tsync_sync.Engine.S) = t.engine in
  match decoded (Some r.identity) with
    | None -> ()
    | Some id when r.flags land is_dir_flag <> 0 ->
        (* §9.2: only a folder the domain holds nothing beneath. *)
        Rt.run_sync (fun () ->
            let path = Handler.path_of_ref t.handler id.ref_ in
            E.atomically (fun () -> E.rmdir path))
    | Some id ->
        ignore
          (Rt.run_sync (fun () ->
               Handler.call t.handler
                 (Delete { item = Ref id.ref_; base = Some id.content_id })))

let rename t (r : Cf.request) =
  match decoded (Some r.identity) with
    | None -> ()
    | Some id when r.flags land target_in_scope_flag <> 0 ->
        let parent_ref = folder_ref t (Filename.dirname r.target) in
        let replaced =
          decoded (try Cf.identity r.target with Failure _ -> None)
        in
        ignore
          (Rt.run_sync (fun () ->
               Handler.call t.handler
                 (Rename
                    {
                      src = id.ref_;
                      at = { parent_ref; name = Filename.basename r.target };
                      noreplace = not (Sys.file_exists r.target);
                      dst_base =
                        Option.map
                          (fun (i : Identity.t) -> i.content_id)
                          replaced;
                    })))
    | Some id ->
        let is_dir = r.flags land is_dir_flag <> 0 in
        make_whole t r.path ~is_dir;
        ignore
          (Rt.run_sync (fun () ->
               if is_dir then Handler.call t.handler (Rmdir (Ref id.ref_))
               else (
                 match
                   Handler.call t.handler
                     (Delete { item = Ref id.ref_; base = Some id.content_id })
                 with
                   | `Deleted | `Kept -> ())))

let acknowledge t (r : Cf.request) what f =
  let status =
    if own r then `Success
    else (
      try
        f t r;
        `Success
      with
        | Refused (status, why) ->
            Log.info "cloud_files: refused on %s: %s" r.path why;
            status
        | e ->
            Log.warn "cloud_files: %s: %s" r.path (Printexc.to_string e);
            mutation_status e)
  in
  Cf.ack t.connection r what status

let handle t (r : Cf.request) =
  try
    match r.kind with
      | `Fetch_placeholders -> fetch_placeholders t r
      | `Fetch_data -> (
          try fetch_data t r
          with Failed_with (status, e) ->
            Log.warn "cloud_files: reading %s: %s" r.path (Printexc.to_string e);
            Cf.transfer_data t.connection r status (Bigstring.create 0)
              ~offset:r.offset ~length:r.length)
      | `Delete -> acknowledge t r `Delete delete
      | `Rename -> acknowledge t r `Rename rename
      | `Dehydrate -> Cf.ack t.connection r `Dehydrate `Success
      | `Close_completion -> if not (own r) then Take.schedule t.take r.path
      | `Cancel_fetch_data | `Cancel_fetch_placeholders | `Other _ -> ()
  with e ->
    Log.err "cloud_files: a callback on %s failed: %s" r.path
      (Printexc.to_string e)

(* §8.3: the shell's cloud icon until the programs carry their own. *)
let icon = "%SystemRoot%\\system32\\imageres.dll,-1043"

let start (domain : Domain.t) engine root applying handler =
  Fs.mkdir_p root;
  let name = Domain_name.to_string domain.name in
  Cf.register
    ~id:(Sync_root_id.id ~sid:(Cf.user_sid ()) domain.name)
    ~path:root ~display_name:name ~version:"1" ~icon;
  let connection = Cf.connect root in
  let take =
    Take.create ~engine ~handler ~root
      ~staging:
        (List.fold_left Filename.concat
           (Tsync_config.Paths.cache_root ())
           [name; "staging"])
      ~read_only:domain.domain.read_only ()
  in
  let apply =
    Apply.create ~engine ~handler ~root ~take
      ~state_file:
        (Filename.concat
           (Tsync_config.Paths.data_dir ())
           ("cloudfiles-" ^ name ^ ".json"))
      ()
  in
  applying := Some apply;
  let t = { engine; root; handler; connection; take; apply } in
  Cf.on_callback (handle t);
  Take.start take;
  Apply.start apply;
  Log.info "cloud_files: %s presented at %s" name root;
  let (_unregister : unit -> unit) =
    Stop.on_request (fun () ->
        try Cf.disconnect connection
        with e ->
          Log.warn "cloud_files: disconnecting %s: %s" root
            (Printexc.to_string e))
  in
  ()

let present root (domain : Domain.t) engine ~publish:_ =
  let applying = ref None in
  let hooks =
    {
      Handler.changed = (fun _ -> Option.iter Apply.wake !applying);
      reannounce = (fun () -> Option.iter Apply.restart_anchor !applying);
      frontend =
        (fun () ->
          Some
            {
              Tsync_status.Status_report.kind = "cloud_files";
              pid = Some (Pid.self ());
              mount = Some root;
              port = None;
              open_handles = None;
              bytes_read = None;
              bytes_written = None;
              shared = false;
              read_only = None;
              shares = None;
              unanswered = false;
            });
    }
  in
  (hooks, fun handler -> start domain engine root applying handler)

let host ~mount:_ domains ~run =
  match domains with
    | [d] -> run (present (Cloud_files_options.sync_root d))
    | _ -> Fail.invalid "cloud_files presents one domain per owner"

let () = Owner.register_host "cloud_files" host
