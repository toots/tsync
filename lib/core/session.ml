external next_event : unit -> int = "tsync_session_event"

let ends = ref []
let locks = ref []
let m = Mutex.create ()
let started = ref false

let run hooks =
  List.iter
    (fun f -> try f () with _ -> ())
    (Mutex.protect m (fun () -> !hooks))

let rec loop () =
  match next_event () with
    | 0 ->
        run ends;
        loop ()
    | 1 ->
        run locks;
        loop ()
    | _ -> loop ()
    | exception Unix.Unix_error (e, _, _) ->
        Log.warn "session: the end and lock of the session go unseen: %s"
          (Unix.error_message e)

let add hooks f =
  Mutex.protect m (fun () ->
      hooks := f :: !hooks;
      if Sys.win32 && not !started then (
        started := true;
        ignore (Thread.create loop ())))

let on_end f = add ends f
let on_lock f = add locks f
