open Cmdliner
open Common

let cmd : unit Cmd.t =
  let mask (b : Conf_parsing.backend_config) k v =
    match Backend_lwt.spec_for b.backend_type with
      | None -> v
      | Some specs -> (
          match List.find_opt (fun (s : Field_spec.t) -> s.name = k) specs with
            | Some { secret = true; _ } when v <> "" -> "***"
            | _ -> v)
  in
  let mask_frontend ftype k v =
    match
      List.find_opt
        (fun (s : Field_spec.t) -> s.name = k)
        (Frontend.spec_for ftype)
    with
      | Some { secret = true; _ } when v <> "" -> "***"
      | _ -> v
  in
  let symlink_str = function
    | `Keep -> "keep"
    | `Follow -> "follow"
    | `Skip -> "skip"
  in
  let run () =
    let cfg = load_config () in
    let default = read_default_domain () in
    Printf.printf "name:            %s\n" cfg.Conf_parsing.name;
    Printf.printf "maxUploads:      %d\n" cfg.Conf_parsing.max_uploads;
    Printf.printf "maxChunkBuffers: %d\n" cfg.Conf_parsing.max_chunk_buffers;
    Printf.printf "maxDownloads:    %d\n" cfg.Conf_parsing.max_downloads;
    (match cfg.Conf_parsing.tls with
      | Some t -> Printf.printf "tls:             %s\n" t
      | None -> ());
    List.iter
      (fun (d : Conf_parsing.domain) ->
        Printf.printf "\ndomain: %s%s\n" d.name
          (if default = Some d.name then " [default]" else "");
        Printf.printf "  versioning: %b\n" d.versioning;
        Printf.printf "  read_only:  %b\n" d.read_only;
        Printf.printf "  symlinks:   %s\n" (symlink_str d.symlink_policy);
        let show_size label = function
          | Some n ->
              Printf.printf "  %-11s %s\n" (label ^ ":") (Metrics.human_bytes n)
          | None -> ()
        in
        show_size "chunkSize" d.chunk_size;
        show_size "cacheChunk" d.cache_chunk_size;
        Printf.printf "  maxCache:   %s\n"
          (match d.max_cache with
            | Some n -> Metrics.human_bytes n
            | None -> "none");
        List.iter
          (fun (f : Conf_parsing.frontend_config) ->
            Printf.printf "  frontend: %s\n" f.frontend_type;
            List.iter
              (fun (k, v) ->
                Printf.printf "    %-22s %s\n" (k ^ ":")
                  (mask_frontend f.frontend_type k v))
              f.options)
          d.frontends;
        List.iter
          (fun (b : Conf_parsing.backend_config) ->
            Printf.printf "  backend: %s (%s) [%s]\n" b.name b.backend_type
              (Conf_parsing.role_name b.role);
            List.iter
              (fun (k, v) ->
                Printf.printf "    %-22s %s\n" (k ^ ":") (mask b k v))
              b.fields)
          d.backends)
      cfg.Conf_parsing.domains
  in
  let edit_arg =
    Arg.(
      value & flag
      & info ["edit"]
          ~doc:
            "Create or edit the configuration interactively instead of \
             printing it.")
  in
  let module W = Wizard.Make (struct
    let config_path = runtime_paths.Runtime.config_path
    let default_domain = read_default_domain
  end) in
  let run edit = if edit then W.run () else run () in
  Cmd.v
    (Cmd.info "config"
       ~doc:
         "Print the configuration as the daemon parsed it, secrets hidden. \
          With $(b,--edit), change it interactively.")
    Term.(const run $ edit_arg)
