(* When to look, not what to do about it: applying foreign entries is
   {!Replay}, which [tsync sync] calls too. Even the when is mostly the store's,
   which says how long a wait for its cursor is worth. *)

module Over
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Js : File_store.OVER with type 'a io := 'a Io.t)
    (Rp : sig
      module Make
          (_ : Conf.S with type 'a io = 'a Io.t)
          (_ : File_ops.S with type 'a io := 'a Io.t) : sig
        val apply_foreign : on_changed:(string -> unit) -> unit -> int Io.t
      end
    end) =
struct
  open Io_syntax.Make (Io)

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

    (* Only ever reached by a failure. The wait is what paces this loop, so
       something that fails without taking any time would otherwise spin. *)
    let retry_floor = 2.

    let start ~on_changed () =
      Io.async (fun () ->
          let step () =
            let* () = Js.wait_cursor_change !last_version in
            let+ (_ : int) = sync_once ~on_changed () in
            ()
          in
          let rec loop () =
            let* () =
              Io.catch step (fun exn ->
                  Log.err "sync_poller: %s" (Printexc.to_string exn);
                  Clock.sleep retry_floor)
            in
            loop ()
          in
          loop ())
  end
end
