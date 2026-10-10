(* The FFmpeg thumbnailer on a still image and two-second videos made here,
   then a share server making a preview through its own link. *)

open Tsync_core
open Tsync_store
module Server = Tsync_http.Server

let video ?(fill = fun i -> i * 4) ?rotation path ~width ~height =
  let out = Av.open_output path in
  let side_data =
    Option.map
      (fun angle ->
        [
          Avutil.Frame_side_data.encode
            (`Display_matrix (Avutil.Display_matrix.make angle));
        ])
      rotation
  in
  let stream =
    Av.new_video_stream ?side_data ~width ~height ~pixel_format:`Yuv420p
      ~frame_rate:{ Avutil.num = 25; den = 1 }
      ~time_base:{ Avutil.num = 1; den = 25 }
      ~codec:(Avcodec.Video.find_encoder_by_name "mpeg4")
      out
  in
  for i = 0 to 49 do
    let frame = Avutil.Video.create_frame width height `Yuv420p in
    ignore
      (Avutil.Video.frame_visit ~make_writable:true
         (Array.iter (fun (data, _) -> Bigarray.Array1.fill data (fill i)))
         frame);
    Avutil.Frame.set_pts frame (Some (Int64.of_int i));
    Av.write_frame stream frame
  done;
  Av.close out

(* A copy of the video whose container asks for borders to be discarded. *)
let cropped ~cropping path copy =
  let input = Av.open_input path in
  let _, stream, params = Av.find_best_video_stream input in
  let out = Av.open_output copy in
  let copied =
    Av.new_stream_copy
      ~params:
        (Avcodec.params_with_side_data params
           [Avcodec.Packet_side_data.encode (`Frame_cropping cropping)])
      out
  in
  let rec copy_packets () =
    match Av.read_input ~video_packet:[stream] input with
      | `Video_packet (_, packet) ->
          Av.write_packet copied (Av.get_time_base stream) packet;
          copy_packets ()
      | _ -> copy_packets ()
      | exception Avutil.Error `Eof -> ()
  in
  copy_packets ();
  Av.close out;
  Av.close input

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

let luma path =
  let input = Av.open_input path in
  let _, stream, _ = Av.find_best_video_stream input in
  match Av.read_input ~video_frame:[stream] input with
    | `Video_frame (_, f) ->
        let y = ref 0 in
        ignore
          (Avutil.Video.frame_visit ~make_writable:false
             (fun planes -> y := Bigarray.Array1.get (fst planes.(0)) 0)
             f);
        Av.close input;
        !y
    | _ -> assert false

(* The [thumbnail] filter passes over the black opening of the video. *)
let fade_in dir =
  let path = Filename.concat dir "fade.mkv" in
  video path ~width:640 ~height:360 ~fill:(fun i -> if i < 12 then 0 else 128);
  let jpeg = Filename.concat dir "fade.jpg" in
  (match Share_preview.make ~kind:`Video path with
    | Some b ->
        Out_channel.with_open_bin jpeg (fun oc ->
            Out_channel.output_string oc (Bigstring.to_string b));
        Printf.printf "fade-in video: picked a lit frame: %b\n" (luma jpeg > 100)
    | None -> print_endline "fade-in video: none");
  Sys.remove path;
  Sys.remove jpeg

(* http-proxy §A9.8 on a listener: an image is made once and then answered from
   the store, a failure is not attempted again, and a share whose file is gone
   gets the generic image. *)
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
  let cs = 65536 in
  let publish name content =
    R.publish ~parent:Folder_id.root ~leaf:name
      (R.upload_chunks ~name ~size:(String.length content) ~chunk_size:cs
         ~mtime:1. (fun i ->
           Bytes
             (Bigstring.of_string
                (String.sub content (i * cs)
                   (min cs (String.length content - (i * cs)))))))
  in
  let share token name =
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
                   `String (Key.to_string (Key.child d Folder_id.root name)) );
                 ("filename", `String name);
                 ("expires", `Int 9_999_999_999);
               ])))
  in
  publish "clip.mkv" (In_channel.with_open_bin video In_channel.input_all);
  publish "noise.mp3" (String.make 4096 'x');
  let token = String.make 32 'a'
  and noise = String.make 32 'b'
  and gone = String.make 32 'c' in
  share token "clip.mkv";
  share noise "noise.mp3";
  share gone "gone.mp4";
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
  let preview label token =
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
    Printf.printf "%s: %s, %s, made so far %d\n" label
      (Option.value ~default:"-" (List.assoc_opt "content-type" r.headers))
      (match r.body with
        | Bigstring b -> (
            match Share_preview.dimensions (Bigstring.to_string b) with
              | Some (w, h) -> Printf.sprintf "%dx%d" w h
              | None -> "not a JPEG")
        | _ -> "the generic image")
      !made
  in
  preview "video" token;
  preview "video again" token;
  preview "undecodable" noise;
  preview "undecodable again" noise;
  preview "file gone" gone;
  Printf.printf "stored: %b\n"
    (Option.fold ~none:false ~some:Share_preview.valid
       (C.store.get_opt (Option.get (Key.share_preview token))));
  Server.close server

let () =
  Rt.run_sync @@ fun () ->
  Printf.printf "available: %b\n" (Share_preview.available ());
  let dir = Filename.temp_dir "tsync-preview" "" in
  let wide = Filename.concat dir "wide.mkv"
  and tall = Filename.concat dir "tall.mkv"
  and sideways = Filename.concat dir "sideways.mp4"
  and narrowed = Filename.concat dir "narrowed.mkv" in
  video wide ~width:1920 ~height:1080;
  video tall ~width:360 ~height:640;
  video sideways ~width:1920 ~height:1080 ~rotation:90.;
  cropped wide narrowed
    ~cropping:{ top = 0; bottom = 0; left = 560; right = 560 };
  show "card" (Sys.getenv "CARD") `Image;
  show "wide video" wide `Video;
  show "tall video, scaled up" tall `Video;
  show "wide video filmed sideways" sideways `Video;
  show "wide video cropped to 800x1080" narrowed `Video;
  show "missing" (Filename.concat dir "missing.mkv") `Video;
  fade_in dir;
  served wide (Filename.concat dir "store");
  Sys.remove wide;
  Sys.remove tall;
  Sys.remove sideways;
  Sys.remove narrowed;
  Fs.rm_rf dir
