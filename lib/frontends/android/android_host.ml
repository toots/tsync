open Tsync_core
open Tsync_config
open Tsync_owner
open Tsync_ipc
module R = Tsync_status.Status_report

(* Linux numbering: the consumer is the Android host. *)
let enoent = 2
let eio = 5
let ebadf = 9
let eacces = 13
let enospc = 28

let errno_of = function
  | Unix.Unix_error (Unix.ENOSPC, _, _) -> enospc
  | e -> (
      match (Fail.classify e).kind with
        | Absent -> enoent
        | Denied -> eacces
        | _ -> eio)

let sentence = function
  | Config.Invalid reason -> reason
  | e -> (Fail.classify e).reason

(* Notices are hints (android §4.2), so the oldest goes when the host does not
   drain them. *)
module Notices = struct
  let limit = 1024
  let m = Mutex.create ()
  let arrived = Condition.create ()
  let pending : string Queue.t = Queue.create ()

  let push json =
    Mutex.protect m (fun () ->
        if Queue.length pending >= limit then ignore (Queue.pop pending);
        Queue.push (Yojson.Safe.to_string json) pending;
        Condition.signal arrived);
    1

  let next () =
    Mutex.protect m (fun () ->
        while Queue.is_empty pending do
          Condition.wait arrived m
        done;
        Queue.pop pending)
end

let next_notice = Notices.next

type host = { trust_store : string; transfer_root : string }

let host : host option Atomic.t = Atomic.make None

let init ~trust_store ~transfer_root =
  Atomic.set host (Some { trust_store; transfer_root });
  Atomic.set Tsync_http.Transport.cleartext_loopback_only true

(* android §4.1: the core's traffic does not pass the platform's cleartext
   switch, so the config is checked here too. *)
let refuse_cleartext (dom : Config.domain) =
  List.iter
    (fun (b : Config.backend) ->
      match Config.str b "url" with
        | Some url when String.starts_with ~prefix:"http://" url ->
            let rest = String.sub url 7 (String.length url - 7) in
            let authority = List.hd (String.split_on_char '/' rest) in
            let name =
              if String.starts_with ~prefix:"[" authority then
                List.hd (String.split_on_char ']' authority) ^ "]"
              else List.hd (String.split_on_char ':' authority)
            in
            if not (Tsync_http.Transport.is_loopback name) then
              raise
                (Config.Invalid
                   (Printf.sprintf
                      "backend %s: %s is a cleartext URL, which this device \
                       refuses; use https://"
                      b.bname url))
        | _ -> ())
    dom.backends

let load ?candidate name =
  let config =
    match
      match candidate with Some _ -> candidate | None -> Paths.read_config ()
    with
      | Some text -> Config.of_string text
      | None -> Fail.absent "no config at %s" (Paths.config_file ())
  in
  let dom =
    Config.resolve ?name:(if name = "" then None else Some name) config
  in
  if Config.frontend dom "android" = None then
    Fail.invalid "%s is not configured with the android frontend"
      (Domain_name.to_string dom.name);
  if Atomic.get host <> None then refuse_cleartext dom;
  (config, dom)

let check_config ?candidate name =
  match load ?candidate name with _ -> "" | exception e -> sentence e

let check_trust_store { trust_store; _ } =
  let certificate = "-----BEGIN CERTIFICATE-----" in
  let holds_one =
    match Fs.read_file_opt trust_store with
      | None -> false
      | Some pem ->
          let n = String.length certificate in
          let rec from i =
            i + n <= String.length pem
            && (String.sub pem i n = certificate || from (i + 1))
          in
          from 0
  in
  if not holds_one then
    Fail.raise_ Fail.Local "the trust store %s holds no certificate" trust_store

type opened = { version : Tsync_sync.Local_ops.handle; size : int }

let handles : (int, opened) Hashtbl.t = Hashtbl.create 16
let handles_m = Mutex.create ()
let last_handle = ref 0

let frontend () : R.frontend option =
  Some
    {
      kind = "android";
      pid = Some (Unix.getpid ());
      mount = None;
      port = None;
      open_handles =
        Some (Mutex.protect handles_m (fun () -> Hashtbl.length handles));
      bytes_read = None;
      bytes_written = None;
      shared = false;
      read_only = None;
      shares = None;
      unanswered = false;
    }

let booted : Owner.embedded option Atomic.t = Atomic.make None
let boot_m = Mutex.create ()

let boot_once ?pull_params name =
  let config, dom = load name in
  Option.iter
    (fun tls ->
      match Tsync_http.Transport.tls_impl_of_string tls with
        | Some impl -> Atomic.set Tsync_http.Transport.tls_impl (Some impl)
        | None -> Fail.invalid "unknown TLS implementation %S" tls)
    config.tls;
  let roots =
    match Atomic.get host with
      | Some h ->
          check_trust_store h;
          [h.transfer_root]
      | None -> [Paths.home ()]
  in
  let owner =
    Owner.embed ?pull_params ~role:"app" ~what:"the tsync app" ~roots
      ~publish:Notices.push ~frontend config dom
  in
  Owner.maintain owner;
  Atomic.set booted (Some owner)

let boot ?pull_params name =
  Mutex.protect boot_m (fun () ->
      if Atomic.get booted <> None then ""
      else (
        match Rt.run_sync (fun () -> boot_once ?pull_params name) with
          | () -> ""
          | exception e -> sentence e))

let reply_in (owner : Owner.embedded) json =
  match Handler.answer owner.handler json with
    | Ipc.Reply reply -> reply
    | Stream run -> run ignore
    | Subscribe _ -> Ipc.failure (Fail.make Fail.Invalid "no subscriptions")

let request_in owner text =
  Yojson.Safe.to_string
    (match Yojson.Safe.from_string text with
      | exception _ -> Ipc.failure (Fail.make Fail.Invalid "invalid JSON")
      | json -> (
          try reply_in owner json with e -> Ipc.failure (Fail.classify e)))

let status_in (owner : Owner.embedded) =
  let name = Domain_name.to_string owner.domain.name in
  let answer =
    match Handler.call owner.handler (Stats []) with
      | a -> Ok a
      | exception e -> Error (sentence e)
  in
  Tsync_status.Status_text.render ~now:(Unix.gettimeofday ())
    {
      host = Unix.gethostname ();
      domains = R.answered [(name, answer)];
      processes = [];
      uplinks = [];
      jobs = [];
      warnings = [];
    }

let open_in (owner : Owner.embedded) ref_ =
  match Handler.open_version owner.handler ref_ with
    | exception e -> -errno_of e
    | version ->
        let size =
          match version.ended with
            | Some (Published m) -> m.size
            | Some (Staged_edit e) -> e.size
            | None -> 0
        in
        Mutex.protect handles_m (fun () ->
            incr last_handle;
            Hashtbl.replace handles !last_handle { version; size };
            !last_handle)

let find handle =
  Mutex.protect handles_m (fun () -> Hashtbl.find_opt handles handle)

let size handle = match find handle with Some o -> o.size | None -> -ebadf

let read_in (owner : Owner.embedded) handle ~off buffer =
  let (module E : Tsync_sync.Engine.S) = owner.engine in
  match find handle with
    | None -> -ebadf
    | Some o -> (
        match E.read o.version ~off ~len:(Bigstring.length buffer) with
          | bytes ->
              let n = Bigstring.length bytes in
              Bigstring.blit ~src:bytes ~src_off:0 ~dst:buffer ~dst_off:0 ~len:n;
              n
          | exception e -> -errno_of e)

let close handle =
  let opened =
    Mutex.protect handles_m (fun () ->
        let o = Hashtbl.find_opt handles handle in
        Hashtbl.remove handles handle;
        o)
  in
  (match (opened, Atomic.get booted) with
    | Some o, Some owner -> (
        let (module E : Tsync_sync.Engine.S) = owner.engine in
        try E.release o.version with _ -> ())
    | _ -> ());
  0

(* Every entry is total: a call before boot is a failure like any other. *)
let not_booted = Fail.make Fail.Unprepared "the core is not booted"

let on_owner ~failed f =
  match Atomic.get booted with
    | None -> failed (Fail.E not_booted)
    | Some owner -> ( try Rt.run_sync (fun () -> f owner) with e -> failed e)

let request text =
  on_owner
    ~failed:(fun e -> Yojson.Safe.to_string (Ipc.failure (Fail.classify e)))
    (fun owner -> request_in owner text)

let status () = on_owner ~failed:sentence status_in
let open_ ref_ = on_owner ~failed:(fun _ -> -eio) (fun o -> open_in o ref_)

let read handle ~off buffer =
  on_owner
    ~failed:(fun e -> -errno_of e)
    (fun owner -> read_in owner handle ~off buffer)
