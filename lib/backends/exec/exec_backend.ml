open Lwt.Syntax

(* Blob storage over an arbitrary command: each operation is a short POSIX-sh
   snippet appended as the final argument of the configured command, with data
   piped over stdin/stdout. ["ssh"; ...; "user@host"] gives remote storage over
   a multiplexed SSH connection; ["sh"; "-c"] runs the same snippets locally.
   The remote side needs POSIX sh, find, xargs and GNU stat (coreutils). *)

(* Snippets exit 200 to report "no such key", so it stays distinct from real
   failures (ssh itself exits 255 on connection errors). *)
let not_found_exit = 200

let make ~command ~root : (module Backend.S) =
  (* Writing to a process that already exited must raise EPIPE, not kill the
     daemon. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let root =
    if String.length root > 1 && root.[String.length root - 1] = '/' then
      String.sub root 0 (String.length root - 1)
    else root
  in
  (* ponytail: fixed limit of 8 concurrent processes (sshd's default
     MaxSessions is 10 per multiplexed connection); make it a config field if
     it ever needs tuning. *)
  let pool = Lwt_pool.create 8 (fun () -> Lwt.return_unit) in
  let run ?(stdin = "") snippet =
    Lwt_pool.use pool (fun () ->
        Lwt_process.with_process_full
          ("", Array.of_list (command @ [snippet]))
          (fun proc ->
            let writer =
              Lwt.catch
                (fun () ->
                  let* () = Lwt_io.write proc#stdin stdin in
                  Lwt_io.close proc#stdin)
                (fun _ -> Lwt.return_unit)
            in
            let* stdout = Lwt_io.read proc#stdout
            and* stderr = Lwt_io.read proc#stderr
            and* () = writer in
            let+ status = proc#status in
            (status, stdout, stderr)))
  in
  let error op key stderr =
    Backend.Backend_error
      (Printf.sprintf "exec %s %s: %s" op key (String.trim stderr))
  in
  let run_ok ?stdin ~op ~key snippet =
    let* status, stdout, stderr = run ?stdin snippet in
    match status with
      | Unix.WEXITED 0 -> Lwt.return stdout
      | _ -> Lwt.fail (error op key stderr)
  in
  let resolve key = if key = "" then root else root ^ "/" ^ key in
  (* Keys with a trailing slash are directory markers, as in the local
     backend. *)
  let is_dir_key key =
    String.length key > 0 && key.[String.length key - 1] = '/'
  in
  let q = Filename.quote in
  let ignore_out (t : string Lwt.t) = Lwt.map ignore t in
  (module struct
    let put ~key ~data () =
      let path = resolve key in
      if is_dir_key key then
        ignore_out
          (run_ok ~op:"put" ~key (Printf.sprintf "mkdir -p %s" (q path)))
      else
        (* Same semantics as the local backend: stage to a unique temp file
           ($$ = remote shell pid) and rename into place; last rename wins. *)
        ignore_out
          (run_ok ~stdin:data ~op:"put" ~key
             (Printf.sprintf
                "mkdir -p %s && cat > %s.$$.tmp && mv -f %s.$$.tmp %s"
                (q (Filename.dirname path))
                (q path) (q path) (q path)))

    let get ~key () =
      run_ok ~op:"get" ~key (Printf.sprintf "cat %s" (q (resolve key)))

    let get_opt ~key () =
      let path = q (resolve key) in
      let* status, stdout, stderr =
        run
          (Printf.sprintf "test -e %s || exit %d; cat %s" path not_found_exit
             path)
      in
      match status with
        | Unix.WEXITED n when n = not_found_exit -> Lwt.return_none
        | Unix.WEXITED 0 -> Lwt.return_some stdout
        | _ -> Lwt.fail (error "get" key stderr)

    let head_opt ~key () =
      let path = q (resolve key) in
      let* status, stdout, stderr =
        run
          (Printf.sprintf
             "test -e %s || exit %d; stat --printf '%%F:%%s:%%Y' %s" path
             not_found_exit path)
      in
      match status with
        | Unix.WEXITED n when n = not_found_exit -> Lwt.return_none
        | Unix.WEXITED 0 -> (
            match String.split_on_char ':' stdout with
              | [ftype; size; mtime] ->
                  let size =
                    if ftype = "directory" then 0 else int_of_string size
                  in
                  Lwt.return_some
                    Backend.{ key; size; last_modified = float_of_string mtime }
              | _ -> Lwt.fail (error "head" key ("bad stat output: " ^ stdout)))
        | _ -> Lwt.fail (error "head" key stderr)

    let delete ~key () =
      ignore_out
        (run_ok ~op:"delete" ~key
           (Printf.sprintf "rm -rf %s" (q (resolve key))))

    let delete_multi keys =
      if keys = [] then Lwt.return_unit
      else begin
        let paths = String.concat "\000" (List.map resolve keys) ^ "\000" in
        ignore_out
          (run_ok ~stdin:paths ~op:"delete_multi" ~key:(List.hd keys)
             "xargs -0 rm -rf --")
      end

    let copy ~src_key ~dst_key () =
      let dst = resolve dst_key in
      if is_dir_key src_key then
        ignore_out
          (run_ok ~op:"copy" ~key:dst_key
             (Printf.sprintf "mkdir -p %s" (q dst)))
      else
        ignore_out
          (run_ok ~op:"copy" ~key:dst_key
             (Printf.sprintf
                "mkdir -p %s && cp -f %s %s.$$.tmp && mv -f %s.$$.tmp %s"
                (q (Filename.dirname dst))
                (q (resolve src_key))
                (q dst) (q dst) (q dst)))

    let list_all ?max_keys ~prefix () =
      let base = resolve prefix in
      let base =
        if String.length base > 1 && base.[String.length base - 1] = '/' then
          String.sub base 0 (String.length base - 1)
        else base
      in
      let qb = q base in
      (* One record per file: "f:<size>:<mtime>:<path>\0"; empty directories
         are listed as "d:..." records so they surface as marker keys, matching
         the local backend. NUL separators survive any path characters. *)
      let* status, stdout, stderr =
        run
          (Printf.sprintf
             "test -e %s || exit %d; find %s -type f -exec stat --printf \
              'f:%%s:%%Y:%%n\\0' {} + && find %s -type d -empty -exec stat \
              --printf 'd:0:%%Y:%%n\\0' {} +"
             qb not_found_exit qb qb)
      in
      let* records =
        match status with
          | Unix.WEXITED n when n = not_found_exit -> Lwt.return_nil
          | Unix.WEXITED 0 ->
              Lwt.return
                (List.filter
                   (fun r -> r <> "")
                   (String.split_on_char '\000' stdout))
          | _ -> Lwt.fail (error "list" prefix stderr)
      in
      let key_of_path path =
        if path = base then Some ""
        else if String.starts_with ~prefix:(base ^ "/") path then begin
          let skip = String.length base + 1 in
          Some (String.sub path skip (String.length path - skip))
        end
        else None
      in
      let entries =
        List.filter_map
          (fun record ->
            match String.split_on_char ':' record with
              | ftype :: size :: mtime :: rest -> (
                  let path = String.concat ":" rest in
                  match (ftype, key_of_path path) with
                    | _, None -> None
                    | "f", Some rel ->
                        Some
                          Backend.
                            {
                              key = prefix ^ rel;
                              size = int_of_string size;
                              last_modified = float_of_string mtime;
                            }
                    (* The base directory itself only surfaces as a marker when
                       the prefix is a directory key, as in the local backend. *)
                    | "d", Some "" when not (is_dir_key prefix) -> None
                    | "d", Some rel ->
                        let key =
                          if rel = "" then prefix else prefix ^ rel ^ "/"
                        in
                        Some
                          Backend.
                            {
                              key;
                              size = 0;
                              last_modified = float_of_string mtime;
                            }
                    | _ -> None)
              | _ -> None)
          records
      in
      let entries =
        List.sort
          (fun a b -> String.compare a.Backend.key b.Backend.key)
          entries
      in
      Lwt.return
        (match max_keys with
          | Some n when List.length entries > n ->
              List.filteri (fun i _ -> i < n) entries
          | _ -> entries)

    let list_directory ~prefix () =
      let+ all = list_all ~prefix () in
      let prefix_len = String.length prefix in
      let dirs = Hashtbl.create 16 in
      let files = ref [] in
      List.iter
        (fun (e : Backend.file_entry) ->
          if String.length e.key <= prefix_len then ()
          else begin
            let rest =
              String.sub e.key prefix_len (String.length e.key - prefix_len)
            in
            match String.index_opt rest '/' with
              | None -> files := e :: !files
              | Some i -> (
                  let dir_name = String.sub rest 0 i in
                  let mtime =
                    if i = String.length rest - 1 then Some e.last_modified
                    else None
                  in
                  match Hashtbl.find_opt dirs dir_name with
                    | None -> Hashtbl.add dirs dir_name mtime
                    | Some None when mtime <> None ->
                        Hashtbl.replace dirs dir_name mtime
                    | Some _ -> ())
          end)
        all;
      let subdirs =
        Hashtbl.fold (fun k mtime acc -> (k, mtime) :: acc) dirs []
      in
      ( List.rev !files,
        List.sort (fun (a, _) (b, _) -> String.compare a b) subdirs )
  end)

let req get ~backend field =
  match get field with
    | Some v -> v
    | None -> failwith (backend ^ " backend: missing field: " ^ field)

let parse_command raw =
  let invalid () =
    failwith
      "exec backend: \"command\" must be a non-empty JSON array of strings"
  in
  match Yojson.Basic.from_string raw with
    | `List (_ :: _ as l) ->
        List.map (function `String s -> s | _ -> invalid ()) l
    | _ -> invalid ()
    | exception _ -> invalid ()

let exec_spec =
  Backend.
    [
      {
        name = "command";
        label = "Command (JSON array)";
        typ = `String;
        default = None;
        secret = false;
      };
      {
        name = "path";
        label = "Storage root path";
        typ = `String;
        default = None;
        secret = false;
      };
    ]

let ssh_spec =
  Backend.
    [
      {
        name = "host";
        label = "SSH host (user@host)";
        typ = `String;
        default = None;
        secret = false;
      };
      {
        name = "path";
        label = "Remote path";
        typ = `String;
        default = None;
        secret = false;
      };
    ]

let () =
  Backend.register ~spec:exec_spec "exec" (fun get ->
      make
        ~command:(parse_command (req get ~backend:"exec" "command"))
        ~root:(req get ~backend:"exec" "path"));
  (* "ssh" is sugar over "exec": a fixed command with connection multiplexing
     baked in. Per-host tweaks (port, key, ...) belong in ~/.ssh/config; use
     the "exec" type for anything beyond that. *)
  Backend.register ~spec:ssh_spec "ssh" (fun get ->
      let command =
        [
          "ssh";
          "-o";
          "ControlMaster=auto";
          "-o";
          "ControlPath=~/.ssh/tsync-%C";
          "-o";
          "ControlPersist=yes";
          req get ~backend:"ssh" "host";
        ]
      in
      make ~command ~root:(req get ~backend:"ssh" "path"))
