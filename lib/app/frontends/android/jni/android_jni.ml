(* The domain as something a host process calls, rather than a binary it execs.

   Everything reachable from C is total: an exception crossing that boundary
   takes the host process with it, and an app has no supervisor to restart it. *)

external log_write : int -> string -> unit = "tsync_log_write"

let rank = function `debug -> 0 | `info -> 1 | `warn -> 2 | `err -> 3

(* Before anything that can fail: a message that misses logcat is one nobody
   sees, the event loop's dying words included. *)
let install_log_sink () =
  Log.set_sink (fun level message -> log_write (rank level) message)

(* Lwt never returns a pool thread once it has grown one, so this is a memory
   floor rather than a ceiling. [Frontend.cap_blocking_pool]'s range is a
   server's: its lower bound alone is twice what a phone should hold. *)
let pool_size = 16
let engine : (module Domain_engine.S) option ref = ref None

let serving () =
  match !engine with
    | Some e -> e
    | None -> failwith "tsync: the domain was never started"

(* [""] for the domain the config names by itself. Answers the empty string when
   the domain is serving, else what went wrong. *)
let boot domain =
  try
    install_log_sink ();
    let paths = Runtime.default_paths () in
    let cfg = Conf_parsing.load paths.Runtime.config_path in
    Tls_conf.apply cfg.Conf_parsing.tls;
    let domain = if domain = "" then None else Some domain in
    let conf = Domain.of_config ?domain ~paths cfg in
    let module C = (val conf : Conf_lwt.S) in
    let module E = Domain_engine.Make_over (Lazy_checkout_lwt) (C) in
    Frontend.use_libev ();
    Lwt_unix.set_pool_size pool_size;
    (* Detached work has no caller to fail, and the default hook ends the
       process over a background error the log would have carried. *)
    (Lwt.async_exception_hook :=
       fun exn ->
         Log.err "android: async exception: %s" (Printexc.to_string exn));
    Domain_engine.start_detached (fun ~ready ->
        let open Lwt.Syntax in
        (* Ready on the manifest tree alone: [start_queue] replays the staged
           tree, and the first query would otherwise wait that out. *)
        let* () = E.init () in
        ready ();
        let* () = E.start_queue () in
        (* The same driver the daemon runs, rather than a loop of this
           frontend's own: one written here ran the chunk cap and silently not
           the deferred rescan, and would have missed every sweep added since. *)
        E.run_maintenance ();
        (* [Lwt_main.run] returns when this does, and every query the JNI
           answers needs the loop still turning. The sweep loop that used to sit
           here kept it alive by never finishing, which read as housekeeping and
           was load-bearing; this says so instead. *)
        fst (Lwt.wait ()));
    engine := Some (module E : Domain_engine.S);
    ""
  with exn -> Printexc.to_string exn

(* Errno rather than an exception: the caller is a platform callback whose only
   vocabulary is a number, and flattening everything to EIO loses the difference
   between a missing document and a broken one. *)
let errno = function
  | Unix.ENOENT -> 2
  | Unix.EIO -> 5
  | Unix.EBADF -> 9
  | Unix.EACCES -> 13
  | Unix.ENOSPC -> 28
  | _ -> 5

let failed what exn backtrace =
  Log.err "%s: %s%s" what (Printexc.to_string exn)
    (match backtrace with
      | None -> ""
      | Some bt -> "\n" ^ Printexc.raw_backtrace_to_string bt);
  -5

let guard what f =
  try f () with
    | Unix.Unix_error (e, _, _) -> -errno e
    | Domain_engine.With_backtrace (exn, bt) -> failed what exn (Some bt)
    | exn -> failed what exn None

(* An open document is a key and the size it had when opened, the way FUSE keeps
   nothing per descriptor; the handle spares a manifest lookup per read. *)
type handle = { key : Logical_key.t; size : int64 }

let handles : (int, handle) Hashtbl.t = Hashtbl.create 8
let last_handle = ref 0

let size_of = function
  | `Staged (staged, _) -> staged.Staged_manifest.s_size
  | `Published manifest -> Manifest.size manifest

let opened raw =
  guard "open" (fun () ->
      Domain_engine.on_loop (fun () ->
          let open Lwt.Syntax in
          let module E = (val serving () : Domain_engine.S) in
          let* key = E.Ih.key_of_ref raw in
          match key with
            | None -> Lwt.fail (Unix.Unix_error (Unix.ENOENT, "open", raw))
            | Some key -> (
                let* resolved = E.F.resolve key in
                match resolved with
                  | None ->
                      Lwt.fail (Unix.Unix_error (Unix.ENOENT, "open", raw))
                  | Some content ->
                      incr last_handle;
                      Hashtbl.replace handles !last_handle
                        { key; size = size_of content };
                      Lwt.return !last_handle)))

let size handle =
  match Hashtbl.find_opt handles handle with Some h -> h.size | None -> -1L

let read handle offset buffer =
  guard "read" (fun () ->
      Domain_engine.on_loop (fun () ->
          match Hashtbl.find_opt handles handle with
            | None -> Lwt.fail (Unix.Unix_error (Unix.EBADF, "read", ""))
            | Some h ->
                let module E = (val serving () : Domain_engine.S) in
                (* The handle, not the key: a player opens one file twice, to
                   probe it and to play it, and each walks it at its own pace. *)
                E.F.read ~stream:(string_of_int handle) h.key buffer ~offset))

let close handle =
  guard "close" (fun () ->
      Hashtbl.remove handles handle;
      0)

let () = Callback.register "tsync_jni_boot" boot
let () = Callback.register "tsync_jni_open" opened
let () = Callback.register "tsync_jni_size" size
let () = Callback.register "tsync_jni_read" read
let () = Callback.register "tsync_jni_close" close
