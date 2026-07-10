(* Exercises every exec-backend snippet locally through ["sh"; "-c"] — no ssh
   involved. The snippets need GNU stat; on macOS (BSD stat) the test builds a
   PATH shim pointing "stat" at Homebrew's gstat. Output is deterministic (no
   mtimes printed); the snapshot is pinned in exec_backend_test.expected. *)

open Lwt.Syntax

let read_first_line cmd =
  let ic = Unix.open_process_in cmd in
  let line = try Some (input_line ic) with End_of_file -> None in
  ignore (Unix.close_process_in ic);
  line

let shell_command ~shim_dir =
  if Sys.command "stat --printf '' / >/dev/null 2>&1" = 0 then ["sh"; "-c"]
  else begin
    match read_first_line "command -v gstat 2>/dev/null" with
      | Some gstat ->
          Unix.mkdir shim_dir 0o755;
          Unix.symlink gstat (Filename.concat shim_dir "stat");
          ["env"; "PATH=" ^ shim_dir ^ ":" ^ Sys.getenv "PATH"; "sh"; "-c"]
      | None ->
          failwith "GNU stat not found (install coreutils to run this test)"
  end

let print_entry (e : Backend.file_entry) =
  assert (e.last_modified > 0. || e.size = 0);
  Printf.printf "  %s (%d)\n" e.key e.size

let main () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-exec-test-%d" (Unix.getpid ()))
  in
  Unix.mkdir root 0o755;
  let command = shell_command ~shim_dir:(root ^ ".bin") in
  let (module B : Backend.S) =
    Exec_backend.make ~command ~root:(Filename.concat root "store")
  in
  let head key =
    let+ entry = B.head_opt ~key () in
    (match entry with
      | None -> Printf.printf "head %s: none\n" key
      | Some e ->
          Printf.printf "head %s: size=%d dir=%b\n" key e.size
            (e.last_modified > 0. && e.size = 0
            && key.[String.length key - 1] = '/'));
    entry
  in
  let list_all prefix =
    let+ entries = B.list_all ~prefix () in
    Printf.printf "list_all %S:\n" prefix;
    List.iter print_entry entries
  in
  let* () = B.put ~key:"a.txt" ~data:"hello" () in
  let* data = B.get ~key:"a.txt" () in
  Printf.printf "get a.txt: %S\n" data;
  let* _ = head "a.txt" in
  let* _ = head "missing.txt" in
  let* () = B.put ~key:"dir/" ~data:"" () in
  let* _ = head "dir/" in
  let* () = B.copy ~src_key:"a.txt" ~dst_key:"sub/b.txt" () in
  let* data = B.get ~key:"sub/b.txt" () in
  Printf.printf "get sub/b.txt: %S\n" data;
  (* Hostile key: quoting must survive spaces and quotes. *)
  let* () = B.put ~key:"we ird'name.txt" ~data:"quoted" () in
  let* data = B.get ~key:"we ird'name.txt" () in
  Printf.printf "get we ird'name.txt: %S\n" data;
  let* () = list_all "" in
  let* () = list_all "sub/" in
  let* files, subdirs = B.list_directory ~prefix:"" () in
  print_endline "list_directory \"\":";
  List.iter print_entry files;
  List.iter (fun d -> Printf.printf "  dir %s\n" d) subdirs;
  let* () = B.delete ~key:"a.txt" () in
  let* _ = head "a.txt" in
  let* () = B.delete_multi ["sub/b.txt"; "we ird'name.txt"] in
  let* () = list_all "" in
  (* get on a missing key must raise Backend_error. *)
  let* () =
    Lwt.catch
      (fun () ->
        let* _ = B.get ~key:"missing.txt" () in
        Lwt.fail_with "expected Backend_error")
      (function
        | Backend.Backend_error _ ->
            print_endline "get missing.txt: Backend_error";
            Lwt.return_unit
        | exn -> Lwt.fail exn)
  in
  (* Registered factories: "exec" decodes the command JSON, "ssh" builds one. *)
  let command_json =
    `List (List.map (fun s -> `String s) command) |> Yojson.Basic.to_string
  in
  let (module E : Backend.S) =
    Backend.make ~backend_type:"exec" ~get_field:(function
      | "command" -> Some command_json
      | "path" -> Some (Filename.concat root "store2")
      | _ -> None)
  in
  let* () = E.put ~key:"f.txt" ~data:"via factory" () in
  let* data = E.get ~key:"f.txt" () in
  Printf.printf "factory get f.txt: %S\n" data;
  (* Keys with URL metacharacters: encoding applied by Backend.make wrapper. *)
  let hostile = "dir/img?url=http:%2F%2Fx.com%2Fpic&size=large" in
  let* () = E.put ~key:hostile ~data:"encoded" () in
  let* data = E.get ~key:hostile () in
  Printf.printf "factory get hostile: %S\n" data;
  let* entry = E.head_opt ~key:hostile () in
  (match entry with
    | Some e ->
        Printf.printf "factory head hostile: key=%S size=%d\n" e.key e.size
    | None -> print_endline "factory head hostile: none");
  let* entries = E.list_all ~prefix:"dir/" () in
  Printf.printf "factory list_all dir/:\n";
  List.iter
    (fun (e : Backend.file_entry) -> Printf.printf "  %S (%d)\n" e.key e.size)
    entries;
  ignore
    (Backend.make ~backend_type:"ssh" ~get_field:(function
      | "host" -> Some "user@nowhere"
      | "path" -> Some "/tmp"
      | _ -> None));
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s %s.bin" (Filename.quote root)
          (Filename.quote root)));
  Lwt.return_unit

let () =
  Lwt_main.run (main ());
  print_endline "ok"
