(* The chunk cache keeps a group's state only while it has a partial body or a
   user (pitfall C-4.1): a pass over every group of a domain leaves none. *)

open Tsync_core
open Tsync_checkout

let p fmt = Printf.printf (fmt ^^ "\n%!")

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-cache-states-%d" (Unix.getpid ()))

let () =
  Fs.rm_rf root;
  Fs.mkdir_p root;
  Rt.run_sync (fun () ->
      let bodies = Hashtbl.create 64 in
      let chunk i =
        let body = Bigstring.of_string (Printf.sprintf "chunk %04d" i) in
        let ck = Chunk_key.of_bigstring body in
        Hashtbl.replace bodies (Chunk_key.to_string ck) body;
        (ck, Bigstring.length body)
      in
      let body ck = Hashtbl.find bodies (Chunk_key.to_string ck) in
      let cache fast =
        Cache.create
          ~cache_root:(Filename.concat root (string_of_bool fast))
          ~domain:(Domain_name.v "d") ~cc:8
          ~fast:(fun () -> fast)
          ~get_whole:body
          ~get_range:(fun ck off len -> Bigstring.sub (body ck) ~off ~len)
          ~cap:None
      in
      let group i =
        let ck, len = chunk i in
        let x = { Cache.index = 0; ck; len; off = 0 } in
        ({ Cache.gkey = Cache.group_key [ck]; members = [x]; gsize = len }, x)
      in
      let whole = cache true in
      List.iter
        (fun i ->
          let g, x = group i in
          ignore (Cache.verified_member whole g x))
        (List.init 200 Fun.id);
      p "after reading 200 groups whole: %d states kept" (Cache.tracked whole);
      let ranged = cache false in
      let g, x = group 1000 in
      ignore (Cache.read_piece ranged g x ~coff:0 ~len:3);
      p "a group read in part keeps its state: %d" (Cache.tracked ranged);
      ignore (Cache.read_piece ranged g x ~coff:3 ~len:(x.len - 3));
      p "once its ranges complete it: %d, whole: %b" (Cache.tracked ranged)
        (Cache.is_whole ranged g.gkey));
  Fs.rm_rf root
