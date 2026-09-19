module Make (Io : Io.S) (Clock : Clock.S with type 'a io := 'a Io.t) = struct
  let until_held health ~name ~op ask =
    let stopped, stop = Io.wait () in
    let watch = Health.on_held health (fun () -> Io.wakeup_later stop ()) in
    Io.finalize
      (fun () ->
        Clock.pick
          [
            ask ();
            Io.bind stopped (fun () -> Io.fail (Retry.held ~name ~op health));
          ])
      (fun () ->
        Health.off health watch;
        Io.return ())
end
