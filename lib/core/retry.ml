include Retry_intf

let failed ~kind ~op detail = Failed { kind; op; detail }

let string_of_kind = function
  | Transient -> "transient"
  | Permanent -> "permanent"

(* [Transient] for anything unrecognised, so a failure mode nobody classified
   is waited out rather than abandoning the work. A caller that knows more
   about its own failures answers first and defers here. *)
let classify = function Failed { kind; _ } -> kind | _ -> Transient

(* A request's failure leaves {!LOOP.with_retry} as [Failed], saying whether the
   link caused it, so anything else was raised on this side of the link and
   fails the same way on every try. *)
let classify_in_order = function Failed { kind; _ } -> kind | _ -> Permanent

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

let held ~name ~op health =
  failed ~kind:Transient ~op:(name ^ " " ^ op) (Health.describe health)

(** The one retry loop for a single request, jittered so a fleet that failed
    together does not return together. A caller decides only what [classify]
    means for it; the curve, the cap and the log line are shared, so two of them
    cannot drift into retrying differently. {!Cancelled} is never retried. *)

module Make (Io : Io.S) (Clock : Clock.S with type 'a io := 'a Io.t) :
  LOOP with type 'a io := 'a Io.t = struct
  (* [classify] comes from whoever built the loop, so a caller that knows more
     about its own failures says so once rather than at each request. *)
  let with_retry ?(max_attempts = default_attempts) ?(health = Health.always_up)
      ~classify ~name ~op f =
    let out_of_tries exn =
      Metrics.add_failure 1;
      (* Out of tries on what the link caused: said so in the exception, which
         is whatever a socket, a resolver or a TLS stack raised and tells a
         reader further up nothing. *)
      if classify exn = Transient then begin
        if Clock.is_timeout exn then Metrics.add_timeout 1;
        Io.fail
          (match exn with
            | Failed _ -> exn
            | exn -> failed ~kind:Transient ~op:(name ^ " " ^ op) (reason exn))
      end
      else Io.fail exn
    in
    let again attempt exn =
      let delay =
        backoff ~base:0.5 ~cap:20. attempt *. (0.5 +. Random.float 1.0)
      in
      (* Timeouts are counted apart from the retries they are part of: a link
         that answers slowly and one that stops answering are the same number
         of retries and very different problems. *)
      Metrics.add_retry 1;
      if Clock.is_timeout exn then Metrics.add_timeout 1;
      (* A first or second attempt lost is the link's ordinary weather and is
         counted; from the third on it is worth a line at default verbosity. *)
      (if attempt < 3 then Log.info else Log.warn)
        "%s %s: %s; retrying (%d/%d) in %.1fs" name op (reason exn) attempt
        max_attempts delay;
      Clock.sleep delay
    in
    (* Told how it went and never refused: whether there is anywhere else to
       go is known to whoever chose this member, not down here. *)
    let rec go attempt =
      Io.catch
        (fun () ->
          Io.map
            (fun answer ->
              Health.answered health;
              answer)
            (f ()))
        (function
          | Cancelled as exn -> Io.fail exn
          (* Called back by whoever was waiting, a deadline or a member found
             down: trying again is doing what they stopped asking for, and it
             says nothing about the link. *)
          | exn when Clock.is_cancelled exn -> Io.fail exn
          | exn when classify exn = Transient ->
              (match Health.lost health (reason exn) with
                | `Tripped ->
                    Log.warn "%s %s: %s" name op (Health.describe health)
                | `Up | `Held -> ());
              if attempt < max_attempts then
                Io.bind (again attempt exn) (fun () -> go (attempt + 1))
              else out_of_tries exn
          (* What will not clear is the member answering about one object,
             which says its link is there. *)
          | exn ->
              Health.answered health;
              out_of_tries exn)
    in
    go 1
end
