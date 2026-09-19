open Lwt.Syntax

let reached ?(bound = 30.) expected =
  let deadline = Unix.gettimeofday () +. bound in
  let rec go () =
    if expected () || Unix.gettimeofday () > deadline then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.01 in
      go ()
  in
  go ()

let held ?bound expected =
  let* () = reached ?bound expected in
  let rec stays polls =
    if polls = 0 || not (expected ()) then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.05 in
      stays (polls - 1)
  in
  stays 6
