(* Points, not pixels, and larger than the 16 the menu draws: a retina screen
   asks for three times that, and a picture this small costs a couple of
   kilobytes either way. *)
let max_side = 64

(* An empty result is "no picture here", which is not an error worth raising. *)
external render : string -> int -> string = "caml_preview_thumbnail"

(* QuickLook types a file by the extension on it, and a staged body is named by
   uuid. A hardlink carries the name in its own directory entry, which is what
   the generators read — a symlink does not do: they resolve it and find the
   uuid again. *)
let linked = ref 0

let with_extension ~scratch ~name path f =
  (try Unix.mkdir scratch 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  incr linked;
  let link =
    Filename.concat scratch
      (Printf.sprintf "%d-%d%s" (Unix.getpid ()) !linked
         (Filename.extension name))
  in
  Unix.link path link;
  Fun.protect
    ~finally:(fun () -> try Unix.unlink link with _ -> ())
    (fun () -> f link)

(* Off the event loop: QuickLook goes out to the system's generators, and a
   large scan takes long enough to be felt. *)
let of_file ~scratch ~name path =
  Lwt.catch
    (fun () ->
      Lwt_preemptive.detach
        (fun () ->
          let png =
            with_extension ~scratch ~name path (fun link ->
                render link max_side)
          in
          if png = "" then None else Some png)
        ())
    (fun _ -> Lwt.return_none)
