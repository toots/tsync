type kind = Transient | Permanent

exception Failed of { kind : kind; op : string; detail : string }
exception Cancelled

let failed ~kind ~op detail = Failed { kind; op; detail }

let string_of_kind = function
  | Transient -> "transient"
  | Permanent -> "permanent"

(* [Transient] for anything unrecognised, so a failure mode nobody classified
   is waited out rather than abandoning the work. A caller that knows more
   about its own failures answers first and defers here. *)
let classify = function Failed { kind; _ } -> kind | _ -> Transient

let reason = function
  | Failed { detail; _ } -> detail
  | exn -> Printexc.to_string exn

let () =
  Printexc.register_printer (function
    | Failed { kind; op; detail } ->
        Some (Printf.sprintf "%s: %s (%s)" op detail (string_of_kind kind))
    | Cancelled -> Some "Retry.Cancelled"
    | _ -> None)

let backoff ~base ~cap attempt =
  Float.min cap (base *. (2. ** float_of_int (min 10 (attempt - 1))))
