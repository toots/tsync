(* Every entry native code reaches is total (android §5): an exception crossing
   into C would end a host that has no supervisor. *)
open Tsync_android

let eio = -5
let text f arg = try f arg with e -> Printexc.to_string e
let number f arg = try f arg with _ -> eio

let () =
  Callback.register "tsync_init" (fun trust_store transfer_root ->
      try Android_host.init ~trust_store ~transfer_root with _ -> ());
  (* The domain, then after a NUL the candidate text when there is one. *)
  Callback.register "tsync_check_config"
    (text (fun arg ->
         match String.index_opt arg '\000' with
           | None -> Android_host.check_config arg
           | Some i ->
               Android_host.check_config
                 ~candidate:(String.sub arg (i + 1) (String.length arg - i - 1))
                 (String.sub arg 0 i)));
  Callback.register "tsync_boot" (text Android_host.boot);
  Callback.register "tsync_request" (text Android_host.request);
  Callback.register "tsync_status"
    (text (fun (_ : string) -> Android_host.status ()));
  Callback.register "tsync_next_notice"
    (text (fun (_ : string) -> Android_host.next_notice ()));
  Callback.register "tsync_open" (number Android_host.open_);
  Callback.register "tsync_size" (number Android_host.size);
  Callback.register "tsync_close" (number Android_host.close);
  Callback.register "tsync_read" (fun handle off buffer ->
      try Android_host.read handle ~off buffer with _ -> eio)
