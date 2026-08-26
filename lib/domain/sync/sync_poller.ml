(* The timer, not the algorithm: applying foreign entries is {!Replay}, which
   [tsync sync] calls too. This only decides when to look. *)
(* What this needs below it. *)
module type JOURNAL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val fetch_cursor : unit -> Journal.Entry_key.t option io
  end
end

module type CLOCK = sig
  type 'a io

  val sleep : float -> unit io
end

module Over
    (Io : Io.S)
    (Clock : CLOCK with type 'a io := 'a Io.t)
    (Js : JOURNAL with type 'a io := 'a Io.t)
    (Rp : sig
      module Make
          (_ : Conf.S with type 'a io = 'a Io.t)
          (_ : File_ops.S with type 'a io := 'a Io.t) : sig
        val apply_foreign : on_changed:(string -> unit) -> unit -> int Io.t
      end
    end) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x
  let return_unit = Io.return ()
  let return_some x = Io.return (Some x)
  let return_true = Io.return true
  let return_false = Io.return false

  let rec iter_s f = function
    | [] -> return_unit
    | x :: rest -> Io.bind (f x) (fun () -> iter_s f rest)

  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (F : File_ops.S with type 'a io := 'a Io.t) =
  struct
    module Js = Js.Make (C)
    module Rp = Rp.Make (C) (F)

    let last_version = ref None

    let same v =
      match !last_version with
        | Some prev -> Journal.Entry_key.compare prev v = 0
        | None -> false

    (* The cursor first, and only then the journal. A peer publishes an entry and
       bumps the cursor after it; reading the journal on every tick regardless
       would cost a listing per client per interval for the state that says
       nothing has changed. It also means an entry whose bump never landed is one
       nobody comes looking for. *)
    let sync_once ~on_changed () =
      let* cursor = Js.fetch_cursor () in
      match cursor with
        | None -> Io.return 0
        | Some v when same v -> Io.return 0
        | Some v ->
            (* Recorded only after a clean pass, so a failed one is retried on the
               next tick. *)
            let* n = Rp.apply_foreign ~on_changed () in
            last_version := Some v;
            Io.return n

    let start ~on_changed () =
      Io.async (fun () ->
          let rec loop () =
            let* () = Clock.sleep 2.0 in
            let* () =
              Io.catch
                (fun () ->
                  let+ (_ : int) = sync_once ~on_changed () in
                  ())
                (fun exn ->
                  Log.err "sync_poller: %s" (Printexc.to_string exn);
                  return_unit)
            in
            loop ()
          in
          loop ())
  end
end
