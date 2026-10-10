open Tsync_core
module Scale = Swscale.Make (Swscale.Frame) (Swscale.Frame)

let fit width height =
  let s = Share_preview.size in
  if width >= height then (s, max 1 (height * s / width))
  else (max 1 (width * s / height), s)

(* A backward seek lands on the key frame at or before one second, which is
   the first frame of a shorter video. *)
let frame ~kind ~interrupt url =
  let input = Av.open_input ~interrupt url in
  Fun.protect ~finally:(fun () -> Av.close input) @@ fun () ->
  let _, stream, _ = Av.find_best_video_stream input in
  if kind = `Video then
    Av.seek ~flags:[Seek_flag_backward] ~fmt:`Second ~ts:1L input;
  let rec next () =
    match Av.read_input ~video_frame:[stream] input with
      | `Video_frame (_, f) -> f
      | _ -> next ()
  in
  next ()

let jpeg frame =
  let width = Avutil.Video.frame_get_width frame
  and height = Avutil.Video.frame_get_height frame in
  let out_width, out_height = fit width height in
  let scaled =
    Scale.convert
      (Scale.create [Bicubic] width height
         (Avutil.Video.frame_get_pixel_format frame)
         out_width out_height `Yuvj420p)
      frame
  in
  let opts = Hashtbl.create 2 in
  Hashtbl.replace opts "flags" (`String "+qscale");
  (* [-q:v 4]: four times FF_QP2LAMBDA. *)
  Hashtbl.replace opts "global_quality" (`Int (4 * 118));
  let encoder =
    Avcodec.Video.create_encoder ~opts ~pixel_format:`Yuvj420p ~width:out_width
      ~height:out_height
      ~time_base:{ Avutil.num = 1; den = 1 }
      (Avcodec.Video.find_encoder_by_name "mjpeg")
  in
  let out = Buffer.create 65536 in
  let add packet = Buffer.add_string out (Avcodec.Packet.content packet) in
  Avutil.Frame.set_pts scaled (Some 0L);
  Avcodec.encode encoder add scaled;
  Avcodec.flush_encoder encoder add;
  Bigstring.of_string (Buffer.contents out)

let () =
  Avutil.Log.set_level `Quiet;
  Atomic.set Share_preview.thumbnailer
    (Some
       (fun ~kind ~deadline url ->
         Some
           (jpeg (frame ~kind ~interrupt:(fun () -> Rt.now () > deadline) url))))
