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

(** What a retry loop reports as it goes. A parameter because counting is the
    process's business and not this rule's: the same loop serves a caller that
    keeps no counters at all. *)
module type METRICS = sig
  val add_retry : int -> unit
  val add_timeout : int -> unit
  val add_failure : int -> unit
end

(** The one retry loop for a single request, jittered so a fleet that failed
    together does not return together. A caller decides only what [classify]
    means for it; the curve, the cap and the log line are shared, so two of them
    cannot drift into retrying differently. {!Cancelled} is never retried. *)
module type LOOP = sig
  type 'a io

  val with_retry :
    ?max_attempts:int ->
    classify:(exn -> kind) ->
    name:string ->
    op:string ->
    (unit -> 'a io) ->
    'a io
end

module Make
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Metrics : METRICS) : LOOP with type 'a io := 'a Io.t = struct
  (* [classify] comes from whoever built the loop, so a caller that knows more
     about its own failures says so once rather than at each request. *)
  let with_retry ?(max_attempts = default_attempts) ~classify ~name ~op f =
    let rec go attempt =
      Io.catch f (function
        | Cancelled as exn -> Io.fail exn
        | exn when attempt < max_attempts && classify exn = Transient ->
            let delay =
              backoff ~base:0.5 ~cap:20. attempt *. (0.5 +. Random.float 1.0)
            in
            (* Timeouts are counted apart from the retries they are part of: a
               link that answers slowly and one that stops answering are the
               same number of retries and very different problems. *)
            Metrics.add_retry 1;
            if Clock.is_timeout exn then Metrics.add_timeout 1;
            Log.warn "%s %s: %s; retrying (%d/%d) in %.1fs" name op (reason exn)
              attempt max_attempts delay;
            Io.bind (Clock.sleep delay) (fun () -> go (attempt + 1))
        | exn ->
            Metrics.add_failure 1;
            Io.fail exn)
    in
    go 1
end
