(* Every entry native code reaches is total (android §5): an exception crossing
   into C would end a host that has no supervisor. *)
open Tsync_android

external started : unit -> unit = "tsync_bridge_started_by_ocaml"

let eio = -5
let text f arg = try f arg with e -> Printexc.to_string e
let number f arg = try f arg with _ -> eio

(* The domain, then after a NUL the rest when there is one. *)
let split arg =
  match String.index_opt arg '\000' with
    | None -> (arg, None)
    | Some i ->
        ( String.sub arg 0 i,
          Some (String.sub arg (i + 1) (String.length arg - i - 1)) )

let with_domain f arg =
  let domain, rest = split arg in
  f domain (Option.value ~default:"" rest)

let () =
  Callback.register "tsync_init"
    (fun trust_store transfer_root workers may_block release_growth ->
      let given n = if n > 0 then Some n else None in
      let bounds =
        {
          Android_host.workers = given workers;
          may_block = given may_block;
          release_growth = given release_growth;
        }
      in
      let trust_store = if trust_store = "" then None else Some trust_store in
      try Android_host.init ~bounds ?trust_store ~transfer_root ()
      with e -> Tsync_core.Log.warn "init: %s" (Printexc.to_string e));
  Callback.register "tsync_check_config"
    (text (fun arg ->
         let domain, candidate = split arg in
         Android_host.check_config ?candidate domain));
  Callback.register "tsync_boot" (text Android_host.boot);
  Callback.register "tsync_request" (text (with_domain Android_host.request));
  Callback.register "tsync_setup_link" (text Android_host.setup_link);
  Callback.register "tsync_status" (text Android_host.status);
  Callback.register "tsync_next_notice"
    (text (fun (_ : string) -> Android_host.next_notice ()));
  Callback.register "tsync_open" (number (with_domain Android_host.open_));
  Callback.register "tsync_size" (number Android_host.size);
  Callback.register "tsync_close" (number Android_host.close);
  Callback.register "tsync_read" (fun handle off buffer ->
      try Android_host.read handle ~off buffer with _ -> eio)
