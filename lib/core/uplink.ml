type 'io admission = {
  acquire : bytes:int -> 'io;
  completed : bytes:int -> elapsed:float -> unit;
  abandoned : bytes:int -> unit;
  now : unit -> float;
  waiting : unit -> int;
}

let small_body = ref 65536

module Make (Io : Io.S) (Clock : Clock.S with type 'a io := 'a Io.t) = struct
  open Io_syntax.Make (Io)

  let unbounded =
    {
      acquire = (fun ~bytes:_ -> Io.return ());
      completed = (fun ~bytes:_ ~elapsed:_ -> ());
      abandoned = (fun ~bytes:_ -> ());
      now = Clock.now;
      waiting = (fun () -> 0);
    }

  (* A budget and the line behind it. [armed] is whether a timer is already
     set for the head: one at a time, since a completion may make room sooner
     and pumps then. *)
  type gate = {
    budget : Uplink_budget.t;
    waiters : (int * unit Io.u) Queue.t;
    mutable armed : bool;
  }

  (* Wake, in order, every waiter from the head the budget now admits. *)
  let rec pump g =
    match Queue.peek_opt g.waiters with
      | Some (bytes, wake)
        when Uplink_budget.admits g.budget ~now:(Clock.now ()) ~bytes ->
          ignore (Queue.pop g.waiters);
          Uplink_budget.take g.budget ~now:(Clock.now ()) ~bytes;
          Io.wakeup_later wake ();
          pump g
      | _ -> ()

  (* Set for the moment the head could next pass on refill alone. A head only a
     completion can free sets nothing: that completion will pump. *)
  let rec arm g =
    if not g.armed then
      match Queue.peek_opt g.waiters with
        | None -> ()
        | Some (bytes, _) ->
            let wait =
              Uplink_budget.wait_for g.budget ~now:(Clock.now ()) ~bytes
            in
            if wait < infinity then begin
              g.armed <- true;
              Io.async (fun () ->
                  let+ () = Clock.sleep (Float.max wait 0.001) in
                  g.armed <- false;
                  pump g;
                  arm g)
            end

  (* Synchronous when there is room: no bind before the check, so a caller that
     asks and sends in one turn cannot have the room taken between. *)
  let acquire g ~bytes =
    let now = Clock.now () in
    let ahead = Queue.is_empty g.waiters || bytes <= !small_body in
    if ahead && Uplink_budget.admits g.budget ~now ~bytes then begin
      Uplink_budget.take g.budget ~now ~bytes;
      Io.return ()
    end
    else begin
      let waited, wake = Io.wait () in
      Queue.add (bytes, wake) g.waiters;
      arm g;
      waited
    end

  let left g ~bytes =
    Uplink_budget.release g.budget ~bytes;
    pump g;
    arm g

  let capped ~rate =
    let g =
      {
        budget = Uplink_budget.create ~now:(Clock.now ()) ~rate;
        waiters = Queue.create ();
        armed = false;
      }
    in
    {
      acquire = acquire g;
      completed = (fun ~bytes ~elapsed:_ -> left g ~bytes);
      abandoned = (fun ~bytes -> left g ~bytes);
      now = Clock.now;
      waiting = (fun () -> Queue.length g.waiters);
    }
end
