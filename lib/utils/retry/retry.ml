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

let default_attempts = 8

(* [classify] comes from whoever built the loop, so a caller that knows more
   about its own failures says so once rather than at each request. *)
let with_retry ?(max_attempts = default_attempts) ~classify ~name ~op f =
  let rec go attempt =
    Lwt.catch f (function
      | Cancelled as exn -> Lwt.fail exn
      | exn when attempt < max_attempts && classify exn = Transient ->
          let delay =
            backoff ~base:0.5 ~cap:20. attempt *. (0.5 +. Random.float 1.0)
          in
          (* Timeouts are counted apart from the retries they are part of: a
             link that answers slowly and one that stops answering are the same
             number of retries and very different problems. *)
          Metrics.add_retry 1;
          if exn = Lwt_unix.Timeout then Metrics.add_timeout 1;
          Log.warn "%s %s: %s; retrying (%d/%d) in %.1fs" name op (reason exn)
            attempt max_attempts delay;
          Lwt.bind (Lwt_unix.sleep delay) (fun () -> go (attempt + 1))
      | exn ->
          Metrics.add_failure 1;
          Lwt.fail exn)
  in
  go 1
