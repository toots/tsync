(* A stop publishes the cursor bumps of the uploads that finished, even while
   another upload holds the drain past the grace. The bump is held in memory
   only, so one not published before the exit is one no peer hears about until
   this client runs again. *)

open Lwt.Syntax

let root = Scratch.dir "stop_cursor"
let backend_root = Filename.concat root "backend"
let marker = "STUCK"

(* Never answers a write carrying [marker]: an upload the drain cannot see
   through. *)
let store : (module Backend_lwt.Store) =
  let (module Real : Backend_lwt.Store) = Fixture.local_store backend_root in
  (module struct
    include Real

    let put ~key ~data () =
      let text = Bigstring.to_string data in
      if Str.string_match (Str.regexp_string marker) text 0 then
        fst (Lwt.wait ())
      else Real.put ~key ~data ()
  end)

module C = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "test"
  let domain_prefix = "tsync/test/manifests/"
  let chunk_prefix = "tsync/test/chunks/"
  let versions_prefix = "tsync/test/versions/"
  let journal_prefix = "tsync/test/journal/"
  let cursor_key = Stored_key.in_space ~prefix:"tsync/test/" "cursor"
  let shares_prefix = "tsync/shares/"
  let store = store
  let members = [Backend.member ~name:"local" store]
  let cache_root = Filename.concat root "cache"
  let data_dir = Filename.concat root "data"
  let socket_path = Filename.concat root "s.sock"
  let max_uploads = 2
  let max_chunk_buffers = 2
  let max_downloads = 2
  let chunk_size = Some 64
  let cache_chunk_size = Some 64
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false

  include Conf_lwt.Monad
end

module Lk = Logical_key.Make (C)
module P : Domain_engine.Domain = Domain_engine.Make (C)
module Fs = File_store_lwt.Make (C)

let settle () =
  let rec go n =
    if n = 0 then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.02 in
      go (n - 1)
  in
  go 50

let upload name body =
  let src = Filename.concat root name in
  Out_channel.with_open_bin src (fun oc -> output_string oc body);
  let key = Lk.file @@ name in
  let* () = P.F.create key in
  let* () = P.F.write_whole key ~src_path:src in
  let* () = P.F.close key in
  settle ()

let () =
  (* The first bump publishes at once; the next is held for the interval. *)
  File_store_lwt.set_cursor_flush_interval 3600.;
  Shutdown.grace := 1.;
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s && mkdir -p %s %s" root root backend_root));
  Lwt_main.run
    (let* () = P.start () in
     let* () = upload "first.txt" "first\n" in
     let* first = Fs.fetch_cursor () in
     Printf.printf "first bump published: %b\n" (first <> None);
     let* () = upload "second.txt" "second\n" in
     let* held = Fs.fetch_cursor () in
     Printf.printf "second bump held: %b\n" (held = first);
     let* () = upload "stuck.txt" marker in
     Shutdown.request ();
     let t0 = Unix.gettimeofday () in
     let* () = Domain_engine.drain_for_stop [P.drain] in
     Printf.printf "stop within the grace: %b\n"
       (Unix.gettimeofday () -. t0 < !Shutdown.grace +. 0.5);
     let+ after = Fs.fetch_cursor () in
     Printf.printf "second bump published: %b\n" (after <> first))
