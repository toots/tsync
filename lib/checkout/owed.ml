(* A hand-off between something that produces work and something that performs
   it, when the two are not in step.

   It holds what it is told: a condition alone drops a signal sent while nobody
   is waiting, and here that would be work nobody comes back for. *)

module Make (Lock : Lock.S with type 'a io := 'a Lwt.t) = struct
  type 'a t = { waiting : Lock.condition; held : 'a Queue.t }

  let create () = { waiting = Lock.condition (); held = Queue.create () }

  let signal t x =
    Queue.add x t.held;
    Lock.broadcast t.waiting

  let rec next t =
    match Queue.take_opt t.held with
      | Some x -> Lwt.return x
      | None -> Lwt.bind (Lock.wait t.waiting) (fun () -> next t)

  let pending t = Queue.length t.held
end
