(* A cancelled descriptor wait leaves nothing in the scheduler: on Linux the
   epoll set, which /proc/self/fdinfo lists, no longer holds its descriptor. *)

open Tsync_core

let p fmt = Printf.printf fmt
let number (fd : Unix.file_descr) : int = Obj.magic fd

let epoll_targets () =
  let dir = "/proc/self/fd" in
  Array.to_list (Sys.readdir dir)
  |> List.concat_map (fun n ->
      match Unix.readlink (Filename.concat dir n) with
        | "anon_inode:[eventpoll]" ->
            In_channel.with_open_text ("/proc/self/fdinfo/" ^ n)
              In_channel.input_lines
            |> List.filter_map (fun l -> Scanf.sscanf_opt l "tfd: %d" Fun.id)
        | _ | (exception Unix.Unix_error _) -> [])

let watched fd = List.mem (number fd) (epoll_targets ())

let () =
  Rt.run_sync (fun () ->
      let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      Rt.spawn (fun () ->
          try Rt.with_timeout 0.5 (fun () -> Rt.wait_readable a)
          with Rt.Timeout -> ());
      Rt.sleep 0.2;
      p "a waiting descriptor is watched: %b\n%!" (watched a);
      Rt.sleep 0.6;
      p "once its wait is cancelled, it is not: %b\n%!" (not (watched a));
      Unix.close a;
      Unix.close b)
