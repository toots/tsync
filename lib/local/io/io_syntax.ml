module Make (Io : Io.S) = struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x
  let return_unit = Io.return ()
  let return_some x = Io.return (Some x)
  let return_true = Io.return true
  let return_false = Io.return false

  let rec iter_s f = function
    | [] -> return_unit
    | x :: rest -> Io.bind (f x) (fun () -> iter_s f rest)

  let rec map_s f = function
    | [] -> Io.return []
    | x :: rest ->
        Io.bind (f x) (fun y -> Io.map (fun ys -> y :: ys) (map_s f rest))

  let rec filter_map_s f = function
    | [] -> Io.return []
    | x :: rest ->
        Io.bind (f x) (fun y ->
            Io.map
              (fun ys -> match y with Some y -> y :: ys | None -> ys)
              (filter_map_s f rest))

  let rec fold_left_s f acc = function
    | [] -> Io.return acc
    | x :: rest -> Io.bind (f acc x) (fun acc -> fold_left_s f acc rest)
end
