open Tsync_core
open Tsync_owner
open Tsync_cloud_files_rules
module Domain = Tsync_domain.Domain

type t = { root : string; handler : Handler.t; connection : Cf.connection }

(* cloud-files §12 *)
let status_of_failure = function
  | Fail.E { kind = Absent; _ } -> `Not_in_sync
  | Fail.E { kind = Read_only | Denied; _ } -> `Access_denied
  | Fail.E { kind = Invalid; _ } -> `Invalid
  | Fail.E { kind = Unreachable | Link; _ } -> `Network_unavailable
  | _ -> `Unsuccessful

(* Windows compares paths ignoring case, with either separator. *)
let same_path a b =
  let norm p =
    let p = Cf.upcase (String.map (function '/' -> '\\' | c -> c) p) in
    if String.ends_with ~suffix:"\\" p then String.sub p 0 (String.length p - 1)
    else p
  in
  norm a = norm b

(* §8.1: the sync root itself carries no identity and stands for root. *)
let ref_of t (r : Cf.request) =
  if r.identity = "" && same_path r.path t.root then Some "root"
  else Option.map (fun (i : Identity.t) -> i.ref_) (Identity.decode r.identity)

let rows t ref_ =
  let rec pages after acc =
    let (page : Protocol.page) =
      Handler.call t.handler
        (List_dir { dir = Ref ref_; after; limit = None; pull = `Never })
    in
    let acc = List.rev_append page.items acc in
    match page.next with Some n -> pages (Some n) acc | None -> List.rev acc
  in
  pages None []

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
                   presented))

let handle t (r : Cf.request) =
  try
    match r.kind with
      | `Fetch_placeholders -> fetch_placeholders t r
      | `Fetch_data ->
          Cf.transfer_data t.connection r `Unsuccessful (Bigstring.create 0)
            ~offset:r.offset ~length:r.length
      | `Delete -> Cf.ack t.connection r `Delete `Access_denied
      | `Rename -> Cf.ack t.connection r `Rename `Access_denied
      | `Dehydrate -> Cf.ack t.connection r `Dehydrate `Success
      | `Cancel_fetch_data | `Cancel_fetch_placeholders | `Close_completion
      | `Other _ ->
          ()
  with e ->
    Log.err "cloud_files: a callback on %s failed: %s" r.path
      (Printexc.to_string e)

(* §8.3: the shell's cloud icon until the programs carry their own. *)
let icon = "%SystemRoot%\\system32\\imageres.dll,-1043"

let start (domain : Domain.t) root handler =
  Fs.mkdir_p root;
  let name = Domain_name.to_string domain.name in
  Cf.register
    ~id:(Sync_root_id.id ~sid:(Cf.user_sid ()) domain.name)
    ~path:root ~display_name:name ~version:"1" ~icon;
  let connection = Cf.connect root in
  let t = { root; handler; connection } in
  Cf.on_callback (handle t);
  Log.info "cloud_files: %s presented at %s" name root;
  let (_unregister : unit -> unit) =
    Stop.on_request (fun () ->
        try Cf.disconnect connection
        with e ->
          Log.warn "cloud_files: disconnecting %s: %s" root
            (Printexc.to_string e))
  in
  ()

let present root (domain : Domain.t) _engine ~publish:_ =
  let hooks =
    {
      Handler.no_hooks with
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
  (hooks, fun handler -> start domain root handler)

let host ~mount:_ domains ~run =
  match domains with
    | [d] -> run (present (Cloud_files_options.sync_root d))
    | _ -> Fail.invalid "cloud_files presents one domain per owner"

let () = Owner.register_host "cloud_files" host
