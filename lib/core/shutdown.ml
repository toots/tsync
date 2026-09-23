exception Stopping

let () =
  Printexc.register_printer (function
    | Stopping -> Some "stopping: left for the next start"
    | _ -> None)

let requested_ = ref false
let hooks : (int, unit -> unit) Hashtbl.t = Hashtbl.create 8
let next_hook = ref 0
let grace = ref 10.
let requested () = !requested_

let request () =
  if not !requested_ then begin
    requested_ := true;
    let pending = Hashtbl.fold (fun id f acc -> (id, f) :: acc) hooks [] in
    Hashtbl.reset hooks;
    List.iter (fun (_, f) -> f ()) (List.sort compare pending)
  end

let on_request f =
  if !requested_ then begin
    f ();
    fun () -> ()
  end
  else begin
    let id = !next_hook in
    incr next_hook;
    Hashtbl.replace hooks id f;
    fun () -> Hashtbl.remove hooks id
  end

let reset () =
  requested_ := false;
  Hashtbl.reset hooks

module Sleep (Io : Io.S) (Clock : Clock.S with type 'a io := 'a Io.t) = struct
  let sleep seconds =
    if !requested_ then Io.return `Stopping
    else (
      let stopped, wake = Io.wait () in
      let off = on_request (fun () -> Io.wakeup_later wake `Stopping) in
      Io.finalize
        (fun () ->
          Clock.pick [Io.map (fun () -> `Slept) (Clock.sleep seconds); stopped])
        (fun () ->
          off ();
          Io.return ()))
end
