let checks_ran = ref 0
let failed = ref 0

let check ?why name ok =
  incr checks_ran;
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failed;
    match why with
      | None -> Printf.printf "%s: FAILED\n%!" name
      | Some why -> Printf.printf "%s: FAILED -- %s\n%!" name (why ())
  end

let checks () = !checks_ran
let failures () = !failed
let case name = Printf.printf "\n=== %s\n" name

(* Flushed like {!check}: a suite that waits on something slow prints where it
   got to before it waits, and a line still sitting in the buffer reads as a
   hang. *)
let step fmt = Printf.printf ("  " ^^ fmt ^^ "\n%!")

let report ?expected () =
  (match expected with
    | Some n when n <> !checks_ran ->
        incr failed;
        Printf.printf "\nexpected %d check(s), ran %d\n" n !checks_ran
    | _ -> ());
  Printf.printf "\n%d check(s), %d failure(s)\n" !checks_ran !failed;
  if !failed > 0 then exit 1
