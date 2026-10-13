(* Times the projection of one entry against a main that answers every
   request after a round trip: N creations, then N removals, with one write
   in flight and with PROJECT_WIDTH. Usage: project_latency.exe N MILLISECONDS *)

open Tsync_core
open Tsync_store
open Tsync_remote

let () =
  let n = int_of_string Sys.argv.(1) in
  let round_trip = float_of_string Sys.argv.(2) /. 1000. in
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-project-latency-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let d = Domain_name.v "photos" in
      let inner = Local.create ~name:"main" (Filename.concat root "store") in
      let requests = Atomic.make 0 in
      let far f =
        Atomic.incr requests;
        Rt.sleep round_trip;
        f ()
      in
      let main =
        {
          inner with
          get_opt = (fun k -> far (fun () -> inner.get_opt k));
          put = (fun ?mode k b -> far (fun () -> inner.put ?mode k b));
          delete = (fun k -> far (fun () -> inner.delete k));
          get_many =
            Some (fun keys -> far (fun () -> List.map inner.get_opt keys));
        }
      in
      let knowledge =
        { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }
      in
      let composite =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore ~knowledge
          [{ name = "main"; role = Main; store = main }]
      in
      let module C = struct
        let domain = d
        let store = Composite.store composite
        let composite = composite
        let versioning = true
        let chunk_size_config = Some 8
        let max_downloads = 8
        let max_chunk_buffers = 4
      end in
      let module R = Remote.Make (C) in
      let module P = Projection.Make (C) in
      let content =
        Log_entry.Known
          (R.upload_chunks ~name:"f" ~size:4 ~chunk_size:8 ~mtime:1. (fun _ ->
               Bytes (Bigstring.of_string "body")))
      in
      let place folder i =
        {
          Algebra.parent = Folder_id.root;
          name = Printf.sprintf "%s-%05d" folder i;
        }
      in
      let timed what width commands =
        Atomic.set requests 0;
        let t = Unix.gettimeofday () in
        P.apply ~width ~before_write:ignore commands;
        Printf.printf "%-22s width %d: %6.1f s, %d requests\n%!" what width
          (Unix.gettimeofday () -. t)
          (Atomic.get requests)
      in
      List.iter
        (fun width ->
          let folder = Printf.sprintf "w%d" width in
          let all f = List.init n (fun i -> f (place folder i)) in
          timed "creations" width (all (fun p -> `File (p, None, Some content)));
          timed "removals" width (all (fun p -> `File (p, Some content, None))))
        [1; Tuning.default.project_width]);
  Fs.rm_rf root
