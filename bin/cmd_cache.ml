open Cmdliner
open Cli

(* Residency, both directions. Evicting and fetching are the same operation
   over the same paths with the wire verb swapped, and naming them apart put
   [restore] beside [revert], which recovers a lost thing --
   this one only moves bytes on and off this machine. *)
let cmd : unit Cmd.t =
  let path_arg = Arg.(non_empty & pos_all string [] & info [] ~docv:"PATH") in
  let evict_arg =
    Arg.(
      value & flag
      & info ["evict"] ~doc:"Drop these files or directories from the cache.")
  in
  let fetch_arg =
    Arg.(
      value & flag
      & info ["fetch"]
          ~doc:"Download these files or directories into the cache.")
  in
  let act ~verb ~done_ ~domain paths =
    let socket_path path =
      match domain with
        | Some _ -> domain_socket ?domain ()
        | None -> domain_socket_for_path path
    in
    List.iter
      (fun path ->
        match Ipc.action ~socket_path:(socket_path path) ~path verb with
          | _ -> Printf.printf "%s: %s\n" done_ path
          | exception Failure msg -> Printf.eprintf "Error: %s\n" msg)
      paths
  in
  let run paths domain evict fetch =
    match (evict, fetch) with
      | true, false -> act ~verb:"evict" ~done_:"Evicted" ~domain paths
      | false, true -> act ~verb:"restore" ~done_:"Fetched" ~domain paths
      | true, true ->
          failwith "--evict and --fetch do opposite things; run one."
      | false, false -> failwith "cache needs --evict or --fetch."
  in
  Cmd.v
    (Cmd.info "cache"
       ~doc:
         "Move files on and off this machine: $(b,--evict) drops them from the \
          cache, $(b,--fetch) downloads them into it.")
    Term.(const run $ path_arg $ domain_arg $ evict_arg $ fetch_arg)
