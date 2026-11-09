(* 01 §5: a whole cache body is replaced only by rename, so a read of it is a
   view of its mapping, not a copy on the heap. *)

open Tsync_core
open Tsync_checkout

let p fmt = Printf.printf (fmt ^^ "\n%!")

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-cache-mapped-%d" (Unix.getpid ()))

let mapped path =
  In_channel.with_open_text "/proc/self/maps" In_channel.input_all
  |> String.split_on_char '\n'
  |> List.exists (fun line -> String.ends_with ~suffix:path line)

let () =
  Fs.rm_rf root;
  Fs.mkdir_p root;
  Rt.run_sync (fun () ->
      let body =
        Bigstring.of_string
          (String.init 65536 (fun i -> Char.chr (i land 0xff)))
      in
      let ck = Chunk_key.of_bigstring body in
      let cache =
        Cache.create ~cache_root:root ~domain:(Domain_name.v "d") ~cc:8
          ~fast:(fun () -> true)
          ~get_whole:(fun _ -> body)
          ~get_range:(fun _ off len -> Bigstring.sub body ~off ~len)
          ~cap:None
      in
      let x = { Cache.index = 0; ck; len = Bigstring.length body; off = 0 } in
      let g =
        { Cache.gkey = Cache.group_key [ck]; members = [x]; gsize = x.len }
      in
      let piece = Cache.read_piece cache g x ~coff:4096 ~len:8192 in
      p "the piece holds its bytes: %b"
        (Bigstring.to_string piece
        = Bigstring.to_string (Bigstring.sub body ~off:4096 ~len:8192));
      p "the whole body is read as a mapping: %b"
        (mapped (Cache.whole_path cache g.gkey));
      ignore (Sys.opaque_identity piece));
  Test_support.finish root
