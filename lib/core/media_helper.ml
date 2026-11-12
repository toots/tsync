let executable = if Sys.win32 then "tsync-media.exe" else "tsync-media"

(* The build tree has the helper under its dune name. *)
let candidates () =
  let dir =
    Filename.dirname
      (try Unix.realpath Sys.executable_name
       with Unix.Unix_error _ -> Sys.executable_name)
  in
  [
    Filename.concat dir executable;
    Filename.concat dir "tsync_media.exe";
    Filename.concat
      (Filename.concat
         (Filename.concat (Filename.dirname dir) "libexec")
         "tsync")
      executable;
  ]

let path () =
  match Sys.getenv_opt "TSYNC_MEDIA_HELPER" with
    | Some p when p <> "" -> if Sys.file_exists p then Some p else None
    | _ -> List.find_opt Sys.file_exists (candidates ())

let available () = Option.is_some (path ())
let grace = 1.

let encode ~deadline request =
  List.iter
    (fun line ->
      if String.contains line '\n' then
        invalid_arg "Media_helper.run: a request line holds a newline")
    request;
  String.concat "\n"
    (Printf.sprintf "%.3f" (Float.max 0. (deadline -. Rt.now ())) :: request)
  ^ "\n"

let read_request input =
  match String.split_on_char '\n' input with
    | seconds :: request -> (
        let request =
          match List.rev request with
            | "" :: rest -> List.rev rest
            | _ -> request
        in
        match float_of_string_opt seconds with
          | Some s when s >= 0. && request <> [] ->
              Some (Rt.now () +. s, request)
          | _ -> None)
    | [] -> None

let write_all fd s =
  let b = Bytes.unsafe_of_string s in
  let rec go off =
    if off < Bytes.length b then
      go (off + Unix.write fd b off (Bytes.length b - off))
  in
  go 0

(* Unix.select takes no pipe on Windows: there the helper's own deadline is
   the only one. *)
let readable fd ~deadline =
  Sys.win32
  ||
  let rec wait () =
    let left = deadline -. Rt.now () in
    left > 0.
    &&
      match Unix.select [fd] [] [] left with
      | [], _, _ -> wait ()
      | _ -> true
      | exception Unix.Unix_error (EINTR, _, _) -> wait ()
  in
  wait ()

(* Reads to the end, or stops at the deadline or past [max_output]. *)
let collect fd ~deadline ~max_output =
  let out = Buffer.create 65536 and chunk = Bytes.create 65536 in
  let rec go () =
    if not (readable fd ~deadline) then None
    else (
      match Unix.read fd chunk 0 (Bytes.length chunk) with
        | 0 -> Some (Buffer.contents out)
        | n ->
            Buffer.add_subbytes out chunk 0 n;
            if Buffer.length out > max_output then None else go ()
        | exception Unix.Unix_error (EINTR, _, _) -> go ())
  in
  go ()

let rec reap pid =
  match Unix.waitpid [] pid with
    | _, status -> status
    | exception Unix.Unix_error (EINTR, _, _) -> reap pid

let spawn exe =
  let input_r, input_w = Unix.pipe ~cloexec:true () in
  let output_r, output_w = Unix.pipe ~cloexec:true () in
  match Unix.create_process exe [| exe |] input_r output_w Unix.stderr with
    | pid ->
        Unix.close input_r;
        Unix.close output_w;
        (pid, input_w, output_r)
    | exception e ->
        List.iter Unix.close [input_r; input_w; output_r; output_w];
        raise e

let run ?(max_output = 16 * 1024 * 1024) ~deadline request =
  let encoded = encode ~deadline request in
  match path () with
    | None -> None
    | Some exe ->
        (* A helper that exits before reading its request must not take the
           process down with it. *)
        Fs.ignore_sigpipe ();
        Rt.within `Threaded (fun () ->
            let pid, input, output = spawn exe in
            let output_read =
              Fun.protect
                ~finally:(fun () -> Unix.close output)
                (fun () ->
                  Fun.protect
                    ~finally:(fun () -> Unix.close input)
                    (fun () ->
                      try write_all input encoded
                      with Unix.Unix_error (EPIPE, _, _) -> ());
                  collect output ~deadline:(deadline +. grace) ~max_output)
            in
            if output_read = None then (
              try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
            match (output_read, reap pid) with
              | Some image, WEXITED 0 -> Some image
              | _ -> None)
