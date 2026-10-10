(* The FFmpeg thumbnailer on a still image and two-second videos made here,
   then a share server making a preview through its own link. *)

open Tsync_core
open Tsync_store
module Server = Tsync_http.Server

let video path ~width ~height =
  let out = Av.open_output path in
  let stream =
    Av.new_video_stream ~width ~height ~pixel_format:`Yuv420p
      ~frame_rate:{ Avutil.num = 25; den = 1 }
      ~time_base:{ Avutil.num = 1; den = 25 }
      ~codec:(Avcodec.Video.find_encoder_by_name "mpeg4")
      out
  in
  for i = 0 to 49 do
    let frame = Avutil.Video.create_frame width height `Yuv420p in
    ignore
      (Avutil.Video.frame_visit ~make_writable:true
         (Array.iter (fun (data, _) -> Bigarray.Array1.fill data (i * 4)))
         frame);
    Avutil.Frame.set_pts frame (Some (Int64.of_int i));
    Av.write_frame stream frame
  done;
  Av.close out

let show name path kind =
  match Share_preview.make ~kind path with
    | None -> Printf.printf "%s: none\n" name
    | Some b -> (
        match Share_preview.dimensions (Bigstring.to_string b) with
          | Some (w, h) ->
              Printf.printf "%s: %dx%d, within %d bytes: %b\n" name w h
                Share_preview.max_bytes
                (Bigstring.length b <= Share_preview.max_bytes)
          | None -> Printf.printf "%s: not a JPEG\n" name)

(* http-proxy §A9.8 on a listener: the first [preview] makes and stores the
   image, the second answers it without making another. *)
let served video root =
  let d = Domain_name.v "photos" in
  let composite =
    Composite.create ~domain:d
      ~data_dir:(Filename.concat root "data")
      ~owner:true ~poke:ignore
      ~knowledge:{ is_index = (fun _ -> false); is_journal = (fun _ -> false) }
      [
        {
          name = "main";
          role = Main;
          store = Local.create ~name:"main" (Filename.concat root "main");
        };
      ]
  in
  let module C = struct
    let domain = d
    let store = Composite.store composite
    let composite = composite
    let versioning = false
    let chunk_size_config = Some 65536
    let max_downloads = 8
    let max_chunk_buffers = 4
  end in
  let module R = Tsync_remote.Remote.Make (C) in
  let content = In_channel.with_open_bin video In_channel.input_all in
  let cs = 65536 in
  R.publish ~parent:Folder_id.root ~leaf:"clip.mkv"
    (R.upload_chunks ~name:"clip.mkv" ~size:(String.length content)
       ~chunk_size:cs ~mtime:1. (fun i ->
         Bytes
           (Bigstring.of_string
              (String.sub content (i * cs)
                 (min cs (String.length content - (i * cs)))))));
  let token = String.make 32 'a' in
  C.store.put
    (Option.get (Key.share token))
    (Bigstring.of_string
       (Yojson.Safe.to_string
          (`Assoc
             [
               ("v", `Int 1);
               ("domain", `String "photos");
               ("type", `String "file");
               ( "key",
                 `String (Key.to_string (Key.child d Folder_id.root "clip.mkv"))
               );
               ("filename", `String "clip.mkv");
               ("expires", `Int 9_999_999_999);
             ])));
  let share = Tsync_http_proxy.Share_server.of_context (module C) in
  let self = ref "" in
  let server =
    Server.serve
      [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)]
      (fun r _ ->
        match String.split_on_char '/' r.path with
          | [""; "s"; token; sub] ->
              Tsync_http_proxy.Share_server.handle ~self:!self share ~tls:false
                ~max_zip_members:10 r ~token ~sub []
          | _ -> Server.text 404 "not found")
  in
  (self :=
     match Server.addresses server with
       | [ADDR_INET (_, port)] -> Printf.sprintf "http://127.0.0.1:%d" port
       | _ -> assert false);
  let made = ref 0 in
  let thumbnail = Option.get (Atomic.get Share_preview.thumbnailer) in
  Atomic.set Share_preview.thumbnailer
    (Some
       (fun ~kind ~deadline url ->
         incr made;
         thumbnail ~kind ~deadline url));
  let preview () =
    let r =
      Tsync_http_proxy.Share_server.handle ~self:!self share ~tls:false
        ~max_zip_members:10
        {
          Server.meth = "GET";
          target = "";
          path = "";
          query = "";
          headers = [];
          peer = "";
          body_length = `Length 0;
        }
        ~token ~sub:"preview" []
    in
    Printf.printf "served preview: %s, %s, made so far %d\n"
      (Option.value ~default:"-" (List.assoc_opt "content-type" r.headers))
      (match r.body with
        | Bigstring b -> (
            match Share_preview.dimensions (Bigstring.to_string b) with
              | Some (w, h) -> Printf.sprintf "%dx%d" w h
              | None -> "not a JPEG")
        | _ -> "the generic image")
      !made
  in
  preview ();
  preview ();
  Printf.printf "stored: %b\n"
    (Option.fold ~none:false ~some:Share_preview.valid
       (C.store.get_opt (Option.get (Key.share_preview token))));
  Server.close server

let () =
  Rt.run_sync @@ fun () ->
  Printf.printf "available: %b\n" (Share_preview.available ());
  let dir = Filename.temp_dir "tsync-preview" "" in
  let wide = Filename.concat dir "wide.mkv"
  and tall = Filename.concat dir "tall.mkv" in
  video wide ~width:1920 ~height:1080;
  video tall ~width:360 ~height:640;
  show "card" (Sys.getenv "CARD") `Image;
  show "wide video" wide `Video;
  show "tall video, scaled up" tall `Video;
  show "missing" (Filename.concat dir "missing.mkv") `Video;
  served wide (Filename.concat dir "store");
  Sys.remove wide;
  Sys.remove tall;
  Fs.rm_rf dir
