let attempts = 8
let base = 0.5
let cap = 20.

(* Unseeded, every client draws the same jitter and retries in step. *)
let () = Random.self_init ()

let delay n =
  let d = min cap (base *. (2. ** float_of_int (min 10 (n - 1)))) in
  d *. (0.5 +. Random.float 1.)

let until_held health ask =
  Rt.first
    [
      ask;
      (fun () ->
        Rt.suspend (fun resolve ->
            Health.on_trip health (fun () -> ignore (resolve (Ok ()))));
        Fail.raise_ Fail.Unreachable "%s is held down" (Health.name health));
    ]

let ladder ?(attempts = attempts) ?deadline ?(health = Health.always_up) ~op f =
  let rec go n =
    match f () with
      | v ->
          Health.answered health;
          v
      | exception ((Stop.Stopping | Rt.Cancelled) as e) -> raise e
      | exception e -> (
          let fl = Fail.classify ~op e in
          let fl = if fl.op = "" then { fl with op } else fl in
          let give_up () = raise (Fail.E fl) in
          match fl.kind with
            | Link | Load | Local | Unexplained ->
                (match fl.kind with
                  | Link -> ignore (Health.lost ~reason:fl.reason health)
                  | Load -> Health.answered health
                  | _ -> ());
                let d = delay n in
                let d =
                  match fl.retry_after with
                    | Some h -> max d (min h cap)
                    | None -> d
                in
                let left =
                  match deadline with
                    | Some dl -> dl -. Rt.now ()
                    | None -> infinity
                in
                if n >= attempts || d > left then give_up ()
                else (
                  Stop.sleep d;
                  go (n + 1))
            | Unreachable | Deadline -> give_up ()
            | _ ->
                Health.answered health;
                give_up ())
  in
  go 1
