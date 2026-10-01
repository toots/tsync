external watch_open : string -> Unix.file_descr = "tsync_watch_open"

external watch_drain : Unix.file_descr -> string list * bool
  = "tsync_watch_drain"

type t = { fd : Unix.file_descr }

let open_ dir =
  match watch_open dir with
    | fd -> Some { fd }
    | exception Unix.Unix_error _ -> None

let wait t ~timeout =
  let deadline = Rt.now () +. timeout in
  let rec go () =
    let left = deadline -. Rt.now () in
    if left <= 0. then `Timeout
    else (
      match Rt.wait_readable ~timeout:left t.fd with
        | exception Rt.Timeout -> `Timeout
        | () -> (
            match watch_drain t.fd with
              | _, true -> `Gone
              | names, false ->
                  if List.exists (fun n -> not (Names.is_temp_name n)) names
                  then `Changed
                  else go ()))
  in
  go ()

let close t = try Unix.close t.fd with Unix.Unix_error _ -> ()
