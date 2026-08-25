(* What bounds chunk work is the domain's, not the caller's.

   [Remote.Make] is applied once per role rather than once per domain -- the
   uploader, diagnostics, export, import, the share server. Every one of them
   queues on the same device and spends from the same memory budget, so a pool
   held inside the functor bounds each of them separately and the process admits
   as many multiples of the configured figure as it happens to have callers. A
   proxy serving shares beside a domain engine is two.

   {!Io_lwt.Bounded.totals} sums by name, so what says whether the pools were
   shared or merely counted together is the [max] it reports. *)

open Check

let root = Filename.concat (Filename.get_temp_dir_name ()) "tsync-chunk-pools"
let () = ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)))
let buffers = 2
let downloads = 3

let conf =
  Fixture.conf ~domain:"pools" ~root ~verify_writes:false
    ~max_chunk_buffers:buffers ~max_downloads:downloads ()

module C = (val conf : Conf.S)

let max_of name =
  match
    List.find_opt (fun (n, _, _, _) -> n = name) (Io_lwt.Bounded.totals ())
  with
    | Some (_, _, _, m) -> m
    | None -> 0

let () =
  case "one application";
  let module R1 = Remote.Make (C) in
  ignore R1.known_chunk_count;
  step "chunk buffers %d, downloads %d" (max_of "chunk buffers")
    (max_of "downloads");
  check "the chunk buffer bound is what the domain asked for"
    (max_of "chunk buffers" = buffers);
  check "and so is the download bound" (max_of "downloads" = downloads);

  case "a second role on the same domain";
  (* The share server's: the same domain under a different layout, which is what
     makes it a second application rather than a second domain. *)
  let module R2 = Remote.Make_with_layout (C) (Layout.Identity) in
  ignore R2.known_chunk_count;
  step "chunk buffers %d, downloads %d" (max_of "chunk buffers")
    (max_of "downloads");
  check "a second caller does not raise what the domain admits"
    (max_of "chunk buffers" = buffers);
  check "nor what it will hold in memory at once"
    (max_of "downloads" = downloads);
  report ~expected:4 ()
