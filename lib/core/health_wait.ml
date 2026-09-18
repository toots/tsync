module Make (Io : Io.S) = struct
  let until_held health ~name ~op ask =
    let answer, resolve = Io.wait () in
    let settled = ref false in
    let settle outcome =
      if not !settled then begin
        settled := true;
        Io.wakeup_later resolve outcome
      end
    in
    let watch =
      Health.on_held health (fun () ->
          settle (Error (Retry.held ~name ~op health)))
    in
    Io.async (fun () ->
        Io.catch
          (fun () -> Io.map (fun v -> settle (Ok v)) (ask ()))
          (fun exn ->
            settle (Error exn);
            Io.return ()));
    Io.bind answer (fun outcome ->
        Health.off health watch;
        match outcome with Ok v -> Io.return v | Error exn -> Io.fail exn)
end
