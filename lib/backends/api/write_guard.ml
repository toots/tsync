module State (Io : Io.S) = struct
  module type Store = Backend.S with type 'a io := 'a Io.t

  let mains members =
    List.filter (fun (m : _ Backend.member) -> m.Backend.role = `Main) members

  let health (m : (module Store) Backend.member) =
    let module B = (val m.Backend.backend : Store) in
    B.health

  let offline (m : _ Backend.member) why =
    `Offline
      (Printf.sprintf "the main %S is not online (%s)" m.Backend.name why)

  let state members =
    match
      List.find_opt (fun m -> Health.is_down (health m)) (mains members)
    with
      | Some m -> offline m (Health.describe (health m))
      | None -> `Ok
end

module Over (Io : Io.S) (Clock : Clock.S with type 'a io := 'a Io.t) = struct
  include State (Io)
  module Wait = Health_wait.Make (Io) (Clock)
  open Io_syntax.Make (Io)

  type answer = { seconds : float; cursor : Bigstring.t option }

  let why_not exn =
    if Clock.is_timeout exn then
      Printf.sprintf "no answer within %.0fs" !Health.probe_timeout
    else Retry.reason exn

  let probe (module B : Store) ~cursor_key =
    let started = Unix.gettimeofday () in
    Io.catch
      (fun () ->
        (* A store found to be down has answered the question, whatever its
           request goes on to do. *)
        let+ cursor =
          Clock.with_timeout !Health.probe_timeout (fun () ->
              Wait.until_held B.health ~name:"probe" ~op:"get_opt" (fun () ->
                  B.get_opt ~key:cursor_key ()))
        in
        Ok { seconds = Unix.gettimeofday () -. started; cursor })
      (fun exn ->
        let why = why_not exn in
        (* The deadline cancels the request under it, and a cancelled request
           tells the cell nothing: this main is down on the probe's own answer,
           or the next look would find it unheard from and pay the wait
           again. *)
        if Clock.is_timeout exn then Health.probe_lost B.health why;
        Io.return (Error why))

  (* A main heard from and up is taken at its word, so a run of guarded writes
     costs one look and not one each; one that went down is looked at again
     once its hold has run out, an expired hold being no answer. *)
  let look ~cursor_key members =
    let unheard =
      List.filter
        (fun m ->
          let h = health m in
          (not (Health.sampled h))
          || (Health.is_down h && not (Health.is_held h)))
        (mains members)
    in
    fold_left_s
      (fun found m ->
        match found with
          | `Offline _ -> Io.return found
          | `Ok -> (
              let+ answered = probe m.Backend.backend ~cursor_key in
              match answered with Ok _ -> `Ok | Error why -> offline m why))
      `Ok unheard

  let ensure ~members ~cursor_key ~what (dst : _ Backend.member) =
    if dst.Backend.role = `Main then Io.return ()
    else
      let* looked = look ~cursor_key members in
      match (looked, state members) with
        | `Offline why, _ | `Ok, `Offline why ->
            Io.fail
              (Retry.failed ~kind:Retry.Transient ~op:what
                 (Printf.sprintf
                    "refusing to %s: %s. A replica is never written while the \
                     main is offline, or it holds what nobody can check"
                    what why))
        | `Ok, `Ok -> Io.return ()

  module For (D : sig
    val members : (module Store) Backend.member list
    val cursor_key : Stored_key.t
  end) =
  struct
    let ensure ~what dst =
      ensure ~members:D.members ~cursor_key:D.cursor_key ~what dst
  end
end
