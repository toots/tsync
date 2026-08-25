(* Records this client has written and owes the store.

   A file change writes its own record; sending the bytes is someone else's
   work, on workers, with a width and a retry policy. This is how the one tells
   the other, and it holds what it is told: a condition alone drops a signal
   sent while nobody is waiting, and a dropped signal here is an upload that
   waits for the next start. *)

module Make (Lock : Lock.S with type 'a io := 'a Lwt.t) = struct
  type t = {
    waiting : Lock.condition;
    owed : (Journal.Entry_key.t * Wal.record) Queue.t;
  }

  let create () = { waiting = Lock.condition (); owed = Queue.create () }

  let signal t key r =
    Queue.add (key, r) t.owed;
    Lock.broadcast t.waiting

  let rec next t =
    match Queue.take_opt t.owed with
      | Some owed -> Lwt.return owed
      | None -> Lwt.bind (Lock.wait t.waiting) (fun () -> next t)

  let pending t = Queue.length t.owed
end
