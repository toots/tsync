open Tsync_core
module Scale = Swscale.Make (Swscale.Frame) (Swscale.Frame)

let samples = 10

let fit width height =
  let s = Share_preview.size in
  if width >= height then (s, max 1 (height * s / width))
  else (max 1 (width * s / height), s)

let rec next_frame input stream =
  match Av.read_input ~video_frame:[stream] input with
    | `Video_frame (_, f) -> f
    | _ -> next_frame input stream

(* A backward seek lands on a key frame, so each sample decodes one frame only;
   a video of unknown duration gives its first frame. *)
let candidates ~kind input stream =
  match (kind, Av.get_input_duration ~format:`Millisecond input) with
    | `Video, Some duration ->
        List.filter_map
          (fun i ->
            let ts =
              Int64.(div (mul duration (of_int (i + 1))) (of_int (samples + 1)))
            in
            match
              Av.seek ~flags:[Seek_flag_backward] ~stream ~fmt:`Millisecond ~ts
                input
            with
              | () -> Some (next_frame input stream)
              | exception Avutil.Error `Eof -> None)
          (List.init samples Fun.id)
    | _ -> [next_frame input stream]

(* FFmpeg's [thumbnail] filter keeps the frame whose colour histogram is
   closest to the average of the batch, which passes over black and faded
   frames. *)
let representative = function
  | [frame] -> frame
  | frames ->
      let first = List.hd frames in
      let graph = Avfilter.init () in
      let source =
        Avfilter.attach ~name:"in"
          ~args:
            [
              `Pair
                ( "video_size",
                  `String
                    (Printf.sprintf "%dx%d"
                       (Avutil.Video.frame_get_width first)
                       (Avutil.Video.frame_get_height first)) );
              `Pair
                ( "pix_fmt",
                  `Int
                    (Avutil.Pixel_format.get_id
                       (Avutil.Video.frame_get_pixel_format first)) );
              `Pair ("time_base", `Rational { Avutil.num = 1; den = 1 });
            ]
          Avfilter.buffer graph
      in
      let thumbnail =
        Avfilter.attach ~name:"thumbnail"
          ~args:[`Pair ("n", `Int (List.length frames))]
          (Avfilter.find "thumbnail")
          graph
      in
      let sink = Avfilter.attach ~name:"out" Avfilter.buffersink graph in
      Avfilter.link
        (List.hd source.io.outputs.video)
        (List.hd thumbnail.io.inputs.video);
      Avfilter.link
        (List.hd thumbnail.io.outputs.video)
        (List.hd sink.io.inputs.video);
      let graph = Avfilter.launch graph in
      let push = List.assoc "in" graph.inputs.video in
      List.iteri
        (fun i frame ->
          Avutil.Frame.set_pts frame (Some (Int64.of_int i));
          push (`Frame frame))
        frames;
      push `Flush;
      (List.assoc "out" graph.outputs.video).handler ()

(* The frame as it is meant to be shown: cropped as the container asks and
   turned as its display matrix asks, which a phone leaves on a video filmed
   sideways. *)
let displayed stream frame =
  let converter =
    Avfilter.Utils.init_display_converter
      ?cropping:
        (Avcodec.Packet_side_data.cropping
           (Avcodec.params_side_data (Av.get_codec_params stream)))
      ~time_base:{ Avutil.num = 1; den = 1 }
      ()
  in
  let shown = ref frame in
  let keep f = shown := f in
  Avfilter.Utils.convert_display converter keep (`Frame frame);
  Avfilter.Utils.convert_display converter keep `Flush;
  !shown

let frame ~kind ~interrupt url =
  let input = Av.open_input ~interrupt url in
  Fun.protect ~finally:(fun () -> Av.close input) @@ fun () ->
  let _, stream, _ = Av.find_best_video_stream input in
  displayed stream (representative (candidates ~kind input stream))

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

(* vault §8.1: the centre square of the frame as it is shown, at [side]. *)
let square side frame =
  let graph = Avfilter.init () in
  let source =
    Avfilter.attach ~name:"in"
      ~args:
        [
          `Pair
            ( "video_size",
              `String
                (Printf.sprintf "%dx%d"
                   (Avutil.Video.frame_get_width frame)
                   (Avutil.Video.frame_get_height frame)) );
          `Pair
            ( "pix_fmt",
              `Int
                (Avutil.Pixel_format.get_id
                   (Avutil.Video.frame_get_pixel_format frame)) );
          `Pair ("time_base", `Rational { Avutil.num = 1; den = 1 });
        ]
      Avfilter.buffer graph
  in
  let stage name args =
    Avfilter.attach ~name ~args (Avfilter.find name) graph
  in
  let crop =
    stage "crop"
      [`Pair ("w", `String "min(iw,ih)"); `Pair ("h", `String "min(iw,ih)")]
  in
  let scale =
    stage "scale"
      [
        `Pair ("w", `Int side);
        `Pair ("h", `Int side);
        `Pair ("flags", `String "lanczos");
      ]
  in
  let format = stage "format" [`Pair ("pix_fmts", `String "rgba")] in
  let sink = Avfilter.attach ~name:"out" Avfilter.buffersink graph in
  let link a b =
    Avfilter.link
      (List.hd a.Avfilter.io.outputs.video)
      (List.hd b.Avfilter.io.inputs.video)
  in
  link source crop;
  link crop scale;
  link scale format;
  link format sink;
  let graph = Avfilter.launch graph in
  let push = List.assoc "in" graph.inputs.video in
  Avutil.Frame.set_pts frame (Some 0L);
  push (`Frame frame);
  push `Flush;
  (List.assoc "out" graph.outputs.video).handler ()

let png frame =
  let side = Avutil.Video.frame_get_width frame in
  let encoder =
    Avcodec.Video.create_encoder ~pixel_format:`Rgba ~width:side ~height:side
      ~time_base:{ Avutil.num = 1; den = 1 }
      (Avcodec.Video.find_encoder_by_name "png")
  in
  let out = Buffer.create 65536 in
  let add packet = Buffer.add_string out (Avcodec.Packet.content packet) in
  Avutil.Frame.set_pts frame (Some 0L);
  Avcodec.encode encoder add frame;
  Avcodec.flush_encoder encoder add;
  Buffer.contents out

(* The largest of the halvings of [max_side] whose PNG fits [max_bytes]. *)
let icon ~max_side ~max_bytes ~deadline source =
  let shown =
    frame ~kind:`Image ~interrupt:(fun () -> Rt.now () > deadline) source
  in
  let rec fit side =
    let encoded = png (square side shown) in
    if String.length encoded <= max_bytes || side <= 16 then encoded
    else fit (side / 2)
  in
  fit
    (min max_side
       (min
          (Avutil.Video.frame_get_width shown)
          (Avutil.Video.frame_get_height shown)))

let () =
  Atomic.set Icon_image.converter (Some icon);
  Avutil.Log.set_level `Quiet;
  Atomic.set Share_preview.thumbnailer
    (Some
       (fun ~kind ~deadline url ->
         Some
           (jpeg (frame ~kind ~interrupt:(fun () -> Rt.now () > deadline) url))))
