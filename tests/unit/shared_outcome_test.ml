(* Work shared by concurrent callers hands each of them its real outcome. *)

open Tsync_core
open Tsync_store
open Tsync_checkout

let p fmt = Printf.printf (fmt ^^ "\n%!")

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-shared-%d" (Unix.getpid ()))

let outcome f =
  match f () with
    | _ -> "ok"
    | exception Fail.E f -> Fail.kind_name f.kind
    | exception Rt.Timeout -> "still waiting"
    | exception e -> Printexc.to_string e

let () =
  Fs.rm_rf root;
  Fs.mkdir_p root;
  Rt.run_sync (fun () ->
      p "== a failed fetch, as its waiter sees it";
      let body = Bigstring.of_string "chunk" in
      let ck = Chunk_key.of_bigstring body in
      let release = Rt.Promise.create () in
      let cache =
        Cache.create ~cache_root:root ~domain:(Domain_name.v "d") ~cc:8
          ~fast:(fun () -> true)
          ~get_whole:(fun _ ->
            Rt.Promise.await release;
            Fail.raise_ Fail.Link "the store went away")
          ~get_range:(fun _ _ _ -> Fail.raise_ Fail.Link "no ranges")
          ~cap:None
      in
      let x = { Cache.index = 0; ck; len = Bigstring.length body; off = 0 } in
      let g =
        { Cache.gkey = Cache.group_key [ck]; members = [x]; gsize = x.len }
      in
      let read () = outcome (fun () -> Cache.verified_member cache g x) in
      let first = Rt.async read in
      Rt.sleep 0.05;
      let waiter = Rt.async read in
      Rt.sleep 0.05;
      Rt.Promise.resolve release ();
      p "  fetching reader: %s" (Rt.Promise.await first);
      p "  waiting reader: %s" (Rt.Promise.await waiter);
      p "== a confirmation that cannot be saved";
      let blocker = Filename.concat root "file" in
      Fs.write_file_for_test blocker "";
      let fn = Bucket_function.open_ ~path:(Filename.concat blocker "saved") in
      let checks = ref 0 in
      let check () =
        incr checks;
        true
      in
      p "  first probe: %s" (outcome (fun () -> Bucket_function.probe fn check));
      p "  next probe: %s"
        (outcome (fun () ->
             Rt.with_timeout 1. (fun () -> Bucket_function.probe fn check)));
      p "  checks run: %d" !checks);
  Fs.rm_rf root
