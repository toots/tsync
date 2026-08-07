(* What the system actually asked the daemon for.

   Whether macOS fetched a file whole or a range at a time is decided inside the
   OS, and once the bytes arrive the two are indistinguishable from outside. The
   request the extension makes on the way past is the only evidence.

   So this stands in front of the daemon's socket and records what goes through.
   A bound unix socket is reached by pathname but lives in its inode, so renaming
   the daemon's socket leaves it listening and reachable at the new name, freeing
   the well-known path for a relay. The daemon needs no test-only code.

   Byte-for-byte in both directions: requests are recorded but never interpreted,
   so a caller that half-closes, streams or pipelines behaves exactly as it would
   against the real socket. *)

type t = {
  path : string;  (** the well-known path, now ours *)
  real : string;  (** where the daemon's socket went *)
  listener : Unix.file_descr;
  inode : int;  (** of the socket we put at [path], to know it is still ours *)
  lock : Mutex.t;
  mutable seen : Yojson.Safe.t list;  (** newest first *)
  mutable stopping : bool;
}

let record tap line =
  if String.trim line <> "" then (
    match Yojson.Safe.from_string line with
      | json ->
          Mutex.lock tap.lock;
          tap.seen <- json :: tap.seen;
          Mutex.unlock tap.lock
      | exception _ -> ())

(* Requests are newline-framed, and a read can land anywhere in one. *)
let split_lines pending chunk =
  Buffer.add_string pending chunk;
  let body = Buffer.contents pending in
  match String.rindex_opt body '\n' with
    | None -> []
    | Some cut ->
        Buffer.clear pending;
        Buffer.add_string pending
          (String.sub body (cut + 1) (String.length body - cut - 1));
        String.split_on_char '\n' (String.sub body 0 cut)

let rec write_all fd buf offset len =
  if len > 0 then (
    let n = Unix.write fd buf offset len in
    if n > 0 then write_all fd buf (offset + n) (len - n))

(* A caller half-closing to say "no more requests" must have that passed on, or
   the daemon waits for a request that is never coming. *)
let relay tap client =
  let up = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let shut fd = try Unix.shutdown fd Unix.SHUTDOWN_SEND with _ -> () in
  let close fd = try Unix.close fd with _ -> () in
  (try
     Unix.connect up (Unix.ADDR_UNIX tap.real);
     let buf = Bytes.create 65536 in
     let pending = Buffer.create 256 in
     let from_client = ref true and from_up = ref true in
     while (!from_client || !from_up) && not tap.stopping do
       let watch =
         (if !from_client then [client] else []) @ if !from_up then [up] else []
       in
       let ready, _, _ =
         if watch = [] then ([], [], []) else Unix.select watch [] [] 0.5
       in
       List.iter
         (fun fd ->
           let n = try Unix.read fd buf 0 (Bytes.length buf) with _ -> 0 in
           if fd == client then
             if n = 0 then (
               from_client := false;
               shut up)
             else begin
               List.iter (record tap)
                 (split_lines pending (Bytes.sub_string buf 0 n));
               write_all up buf 0 n
             end
           else if n = 0 then (
             from_up := false;
             shut client)
           else write_all client buf 0 n)
         ready
     done
   with _ -> ());
  close up;
  close client

(* [stop] closes the listener from another thread, so a wait in progress fails
   rather than returning. Expected. *)
let accept_loop tap =
  while not tap.stopping do
    match Unix.select [tap.listener] [] [] 0.5 with
      | [_], _, _ -> (
          match Unix.accept tap.listener with
            | client, _ -> ignore (Thread.create (relay tap) client)
            | exception _ -> ())
      | _ -> ()
      | exception Unix.Unix_error _ -> tap.stopping <- true
  done

(* The daemon must already be listening on [socket_path]: its socket is what gets
   moved aside, and there is nothing to relay to otherwise. *)
let start ~socket_path =
  if not (Sys.file_exists socket_path) then
    failwith ("no daemon socket at " ^ socket_path);
  let real = socket_path ^ ".tapped" in
  (try Unix.unlink real with _ -> ());
  Unix.rename socket_path real;
  let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_UNIX socket_path);
  Unix.listen listener 64;
  (* The extension is sandboxed and gains nothing by being the same user, so do
     not narrow what the daemon itself published. *)
  (try Unix.chmod socket_path (Unix.stat real).Unix.st_perm with _ -> ());
  let tap =
    {
      path = socket_path;
      real;
      listener;
      inode = (Unix.stat socket_path).Unix.st_ino;
      lock = Mutex.create ();
      seen = [];
      stopping = false;
    }
  in
  ignore (Thread.create accept_loop tap);
  tap

(* Only if the socket there is still the one this put down: a daemon that
   restarted while the tap was up has bound the path again, and restoring over
   that would unlink a live socket in favour of a dead one. In that case the moved
   socket is the stale one and simply goes. *)
let stop tap =
  tap.stopping <- true;
  (try Unix.close tap.listener with _ -> ());
  let ours =
    match Unix.stat tap.path with
      | stats -> stats.Unix.st_ino = tap.inode
      | exception _ -> false
  in
  if ours then begin
    (try Unix.unlink tap.path with _ -> ());
    try Unix.rename tap.real tap.path with _ -> ()
  end
  else (try Unix.unlink tap.real with _ -> ())

let seen tap =
  Mutex.lock tap.lock;
  let all = List.rev tap.seen in
  Mutex.unlock tap.lock;
  all

let forget tap =
  Mutex.lock tap.lock;
  tap.seen <- [];
  Mutex.unlock tap.lock

let field key json =
  match json with
    | `Assoc l -> (
        match List.assoc_opt key l with Some v -> v | None -> `Null)
    | _ -> `Null

(* Every request recorded for [action], in the order it was made. *)
let requests tap action =
  List.filter (fun j -> field "action" j = `String action) (seen tap)
