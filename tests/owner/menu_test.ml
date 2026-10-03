(* The menu model (07 §5.8) from synthetic status answers. *)
open Tsync_owner

let status ?(paused = false) ?(uploading = []) ?(downloading = [])
    ?(pending_uploads = List.length uploading) ?(pending_bytes = 0)
    ?(up_bytes = 0) ?(up_rate = 0.) domain : Protocol.status =
  {
    domain;
    read_only = false;
    paused;
    pending_uploads;
    pending_downloads = List.length downloading;
    uploading;
    downloading;
    pending_bytes;
    subscribers = 1;
    unnamed = 0;
    traffic = { up_bytes; up_rate; down_bytes = 0; down_rate = 0. };
    mount = None;
  }

let file ?(bytes = 0) ?(size = 0) rel : Protocol.transfer =
  { name = Filename.basename rel; rel; bytes; size; seconds = 1.; rate = 0. }

let show label answers =
  Printf.printf "== %s\n" label;
  match Menu.render answers with
    | `Assoc l -> (
        Printf.printf "icon %s, tooltip %s\n"
          (Yojson.Safe.to_string (List.assoc "icon" l))
          (Yojson.Safe.to_string (List.assoc "tooltip" l));
        match List.assoc "entries" l with
          | `List entries ->
              List.iter
                (fun e -> Printf.printf "  %s\n" (Yojson.Safe.to_string e))
                entries
          | _ -> ())
    | _ -> ()

let () =
  show "no domains" [];
  show "idle" [("Files", Ok (status "Files"))];
  show "unreachable" [("Files", Error "no owner")];
  let uploads = List.init 7 (fun i -> file (Printf.sprintf "dir/f%d.bin" i)) in
  show "uploading seven, 2 GiB to go at 1 MiB/s"
    [
      ( "Files",
        Ok
          (status
             ~uploading:(List.filteri (fun i _ -> i < 7) uploads)
             ~pending_uploads:9
             ~pending_bytes:(2 * 1024 * 1024 * 1024)
             ~up_bytes:(300 * 1024 * 1024)
             ~up_rate:(1024. *. 1024.) "Files") );
    ];
  show "a download, one domain paused"
    [
      ( "Files",
        Ok
          (status ~downloading:[file ~bytes:40 ~size:100 "a/movie.mkv"] "Files")
      );
      ("Archive", Ok (status ~paused:true "Archive"));
    ];
  show "all paused, under a minute left"
    [
      ( "Files",
        Ok
          (status ~paused:true
             ~uploading:[file "x"]
             ~pending_bytes:1000 ~up_rate:100. "Files") );
    ]
