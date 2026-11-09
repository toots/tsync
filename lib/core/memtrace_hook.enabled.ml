(* Log depends on Rt, which calls this before it starts: messages go to stderr. *)

let default_rate = 1e-5

let sampling_rate () =
  match
    Option.bind (Sys.getenv_opt "TSYNC_MEMTRACE_RATE") float_of_string_opt
  with
    | Some rate when rate > 0. && rate <= 1. -> rate
    | _ -> default_rate

let start () =
  match Sys.getenv_opt "TSYNC_MEMTRACE_DIR" with
    | None | Some "" -> ()
    | Some dir -> (
        let filename =
          Filename.concat dir (Printf.sprintf "tsync-%d.ctf" (Pid.self ()))
        in
        let context = String.concat " " (Array.to_list Sys.argv) in
        let sampling_rate = sampling_rate () in
        match
          Memtrace.start_tracing ~context:(Some context) ~sampling_rate
            ~filename
        with
          | _ ->
              Printf.eprintf "memtrace: tracing to %s at rate %g\n%!" filename
                sampling_rate
          | exception e ->
              Printf.eprintf "memtrace: cannot trace to %s: %s\n%!" filename
                (Printexc.to_string e))
