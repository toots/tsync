open Tsync_core

type t = {
  path : string;
  m : Mutex.t;
  mutable probing : bool Rt.Promise.t option;
}

let validity = 7. *. 86400.
let open_ ~path = { path; m = Mutex.create (); probing = None }

let confirmed_at t =
  Option.bind (Fs.read_file_opt t.path) (fun s ->
      float_of_string_opt (String.trim s))

let confirmed ?(now = Unix.gettimeofday ()) t =
  match confirmed_at t with Some at -> now -. at < validity | None -> false

let due t = not (confirmed ~now:(Unix.gettimeofday () +. 86400.) t)

let probe t check =
  let answer, mine =
    Mutex.protect t.m (fun () ->
        match t.probing with
          | Some p -> (p, false)
          | None ->
              let p = Rt.Promise.create () in
              t.probing <- Some p;
              (p, true))
  in
  if mine then (
    let r = try Ok (check ()) with e -> Error e in
    (match r with
      | Ok true -> (
          try
            Fs.mkdir_p (Filename.dirname t.path);
            Fs.durable_replace ~perm:0o600 t.path
              (Printf.sprintf "%.3f\n" (Unix.gettimeofday ()))
          with e ->
            Log.warn "cannot record the bucket function's confirmation: %s"
              (Printexc.to_string e))
      | _ -> ());
    Mutex.protect t.m (fun () -> t.probing <- None);
    ignore (Rt.Promise.try_resolve_result answer r));
  Rt.Promise.await answer
