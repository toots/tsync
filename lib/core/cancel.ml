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
  let rec take n acc = function
    | x :: rest when n > 0 -> take (n - 1) (x :: acc) rest
    | rest -> (List.rev acc, rest)
  in
  let rec go = function
    | [] -> `Done
    | _ when cancelled () -> `Cancelled
    | items ->
        let batch, rest = take size [] items in
        f batch;
        go rest
  in
  go items
