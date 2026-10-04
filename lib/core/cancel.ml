let check cancelled = if cancelled () then Fail.raise_ Fail.Refused "cancelled"

let race cancelled f =
  Rt.first
    [
      f;
      (fun () ->
        let rec watch () =
          check cancelled;
          Rt.sleep 0.25;
          watch ()
        in
        watch ());
    ]

let batches ?(size = 1000) cancelled f items =
  let rec go = function
    | [] -> `Done
    | _ when cancelled () -> `Cancelled
    | items ->
        let batch, rest = Pages.take size items in
        f batch;
        go rest
  in
  go items
