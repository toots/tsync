(* linux-desktop.md §6.5: every request of the tray, against an owner that
   accepts and never answers, one that sends bytes without ending its line,
   and one that is not listening, ends by its deadline with no answer. *)
open Tsync_core
open Tsync_ipc

let dir = Printf.sprintf "/tmp/tsync-wedged-%d" (Unix.getpid ())
let deadline = 0.5
let margin = 0.3
let owner_double = Filename.concat (Sys.getcwd ()) Sys.argv.(1)

let double mode socket =
  let pid =
    Unix.create_process owner_double
      [| owner_double; mode; socket |]
      Unix.stdin Unix.stderr Unix.stderr
  in
  let rec wait n =
    if not (Sys.file_exists socket) then
      if n = 0 then failwith "the double did not start"
      else (
        Unix.sleepf 0.05;
        wait (n - 1))
  in
  wait 100;
  pid

let requests =
  [
    ("status", `Assoc [("action", `String "status")]);
    ("stats", `Assoc [("action", `String "stats")]);
    ("pause", `Assoc [("action", `String "pause"); ("arg", `String "on")]);
  ]

let () =
  Fs.mkdir_p ~perm:0o700 dir;
  let owners =
    List.map
      (fun mode ->
        let socket = Filename.concat dir (mode ^ ".sock") in
        (mode, socket, double mode socket))
      ["silent"; "trickle"]
  in
  let checked = ref 0 in
  Rt.run_sync (fun () ->
      List.iter
        (fun (owner, socket) ->
          List.iter
            (fun (name, request) ->
              let started = Rt.now () in
              let answer = Ipc.ask ~deadline socket request in
              let elapsed = Rt.now () -. started in
              incr checked;
              Printf.printf "%-13s %-6s -> %s, by the deadline: %b\n" owner name
                (match answer with
                  | None -> "no answer"
                  | Some j -> Yojson.Safe.to_string j)
                (elapsed <= deadline +. margin))
            requests)
        (List.map (fun (mode, socket, _) -> (mode, socket)) owners
        @ [("not listening", Filename.concat dir "nobody.sock")]));
  List.iter (fun (_, _, pid) -> Unix.kill pid Sys.sigkill) owners;
  Fs.rm_rf dir;
  if !checked = 0 then failwith "no exchange ran";
  Printf.printf "%d exchanges\n" !checked
