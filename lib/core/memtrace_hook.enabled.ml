(* Log depends on Rt, which calls this before it starts: messages go to stderr.

   This needs memtrace v0.18 or later, whose tracer is safe with several domains;
   [Memtrace.stop_tracing ()] does not type-check against 0.2.3, so a build
   that finds the old release fails here instead of tracing unsafely. *)

let default_rate = 1e-5

let sampling_rate () =
  match Sys.getenv_opt "TSYNC_MEMTRACE_RATE" with
    | None | Some "" -> default_rate
    | Some text -> (
        match float_of_string_opt text with
          | Some rate when rate > 0. && rate <= 1. -> rate
          | _ ->
              Printf.eprintf
                "memtrace: TSYNC_MEMTRACE_RATE=%S is not a rate in (0, 1]; \
                 using %g\n\
                 %!"
                text default_rate;
              default_rate)

(* The process's role, as in "owner --domain Files", not its whole command
   line: a command's arguments may hold secrets. *)
let role () =
  let rec domain = function
    | "--domain" :: name :: _ -> [name]
    | _ :: rest -> domain rest
    | [] -> []
  in
  match Array.to_list Sys.argv with
    | _ :: command :: rest -> String.concat " " (command :: domain rest)
    | _ -> "tsync"

let start () =
  match Sys.getenv_opt "TSYNC_MEMTRACE_DIR" with
    | None | Some "" -> ()
    | Some dir -> (
        let filename =
          Filename.concat dir
            (Printf.sprintf "tsync-%d-%.0f.ctf" (Pid.self ())
               (Unix.gettimeofday ()))
        in
        let sampling_rate = sampling_rate () in
        match
          Memtrace.start_tracing
            ~context:(Some (role ()))
            ~sampling_rate ~filename
        with
          | () ->
              Printf.eprintf "memtrace: tracing to %s at rate %g\n%!" filename
                sampling_rate
          | exception e ->
              Printf.eprintf "memtrace: cannot trace to %s: %s\n%!" filename
                (Printexc.to_string e))

let stop () = Memtrace.stop_tracing ()
