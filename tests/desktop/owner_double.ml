(* Stand-ins for a domain's owner (linux-desktop.md §6.5, linux-tray.md §9):

     owner_double silent SOCKET [DIR]  accepts and never answers
     owner_double trickle SOCKET       sends a byte every 20 ms, never a newline
     owner_double scripted SOCKET DIR  answers each request from DIR

   A scripted owner answers action A with the last line of DIR/A, read at each
   request; a first line [silent] never answers, [wait S] answers S seconds
   late, [close] answers and hangs up, [hangup] hangs up without answering.
   With no such file it answers [ping] ok and refuses the rest.

   Every request line is appended to DIR/requests, and DIR/events says when
   each request arrived and when its client hung up, as [TIME CONNECTION
   request ACTION] and [TIME CONNECTION close]: a test reads the order of
   things from it instead of timing them. An owner that is not listening is
   no process at all. *)

let read_file path =
  match open_in_bin path with
    | ic ->
        Fun.protect
          ~finally:(fun () -> close_in ic)
          (fun () -> Some (really_input_string ic (in_channel_length ic)))
    | exception Sys_error _ -> None

let log_lock = Mutex.create ()

let append dir file line =
  if dir <> "" then
    Mutex.protect log_lock (fun () ->
        let oc =
          open_out_gen [Open_append; Open_creat] 0o600
            (Filename.concat dir file)
        in
        output_string oc (line ^ "\n");
        close_out oc)

let event dir connection what =
  append dir "events"
    (Printf.sprintf "%.6f %d %s" (Unix.gettimeofday ()) connection what)

let action_of line =
  match Yojson.Safe.from_string line with
    | `Assoc l -> (
        match List.assoc_opt "action" l with Some (`String a) -> a | _ -> "")
    | _ | (exception _) -> ""

let answer dir action =
  match read_file (Filename.concat dir action) with
    | None when action = "ping" -> Some {|{"ok":true}|}
    | None -> Some {|{"ok":false,"code":"invalid","error":"unknown action"}|}
    | Some script -> (
        match List.filter (( <> ) "") (String.split_on_char '\n' script) with
          | "silent" :: _ -> None
          | "hangup" :: _ -> raise End_of_file
          | ["close"; reply] -> Some (reply ^ "\n\000")
          | [wait; reply] when String.starts_with ~prefix:"wait " wait ->
              Unix.sleepf
                (float_of_string (String.sub wait 5 (String.length wait - 5)));
              Some reply
          | lines -> Some (List.nth lines (List.length lines - 1)))

let serve mode dir connection fd =
  match mode with
    | "trickle" ->
        while true do
          ignore (Unix.write_substring fd "x" 0 1);
          Unix.sleepf 0.02
        done
    | _ -> (
        let ic = Unix.in_channel_of_descr fd in
        try
          while true do
            let line = input_line ic in
            let action = action_of line in
            append dir "requests" line;
            event dir connection ("request " ^ action);
            match if mode = "silent" then None else answer dir action with
              | Some reply when String.ends_with ~suffix:"\n\000" reply ->
                  ignore
                    (Unix.write_substring fd reply 0 (String.length reply - 1));
                  raise End_of_file
              | Some reply ->
                  let reply = reply ^ "\n" in
                  ignore (Unix.write_substring fd reply 0 (String.length reply))
              | None -> ()
          done
        with End_of_file | Unix.Unix_error _ | Sys_error _ ->
          event dir connection "close";
          Unix.close fd)

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let mode = Sys.argv.(1) and socket = Sys.argv.(2) in
  let dir = if Array.length Sys.argv > 3 then Sys.argv.(3) else "" in
  (try Unix.unlink socket with Unix.Unix_error _ -> ());
  let listener = Unix.socket PF_UNIX SOCK_STREAM 0 in
  Unix.bind listener (ADDR_UNIX socket);
  Unix.listen listener 64;
  print_endline "listening";
  let connections = ref 0 in
  while true do
    let fd, _ = Unix.accept listener in
    incr connections;
    let connection = !connections in
    ignore
      (Thread.create
         (fun () ->
           try serve mode dir connection fd
           with Unix.Unix_error _ | Sys_error _ -> ())
         ())
  done
