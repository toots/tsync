open Lwt.Syntax

(* Long enough to collect a catch-up into few messages, short enough that a
   single foreign rename reaches a mount before anyone looks. *)
let flush_interval = 0.2

(* A replay is as long as what other clients did, so the batch needs a ceiling
   of its own: one line carrying a hundred thousand keys is a line the reader
   has to hold whole. *)
let max_batch = 512

type t = {
  domain : string;
  sockets : string list;
  (* A set: a catch-up that touches one key repeatedly owes one notice. *)
  pending : (string, unit) Hashtbl.t;
  mutable scheduled : bool;
  mutable warned : bool;
}

let table : (string, t) Hashtbl.t = Hashtbl.create 4

let for_domain ~domain ~sockets =
  match Hashtbl.find_opt table domain with
    | Some t -> t
    | None ->
        let t =
          {
            domain;
            sockets;
            pending = Hashtbl.create 64;
            scheduled = false;
            warned = false;
          }
        in
        Hashtbl.replace table domain t;
        t

let rec chunks n = function
  | [] -> []
  | l ->
      let rec take i acc = function
        | rest when i = 0 -> (List.rev acc, rest)
        | [] -> (List.rev acc, [])
        | x :: rest -> take (i - 1) (x :: acc) rest
      in
      let head, rest = take n [] l in
      head :: chunks n rest

let post t keys =
  let line =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("action", `String "changed");
           ("domain", `String t.domain);
           ("keys", `List (List.map (fun k -> `String k) keys));
         ])
  in
  (* The list is the domain's configured frontends. *)
  Lwt_list.iter_p
    (fun socket_path ->
      Lwt.catch
        (fun () ->
          let+ (_ : string) = Ipc.send_lwt ~socket_path line in
          ())
        (fun exn ->
          (* Said once: a frontend that is down would otherwise put a line in
             the log every time anything changed. *)
          if not t.warned then begin
            t.warned <- true;
            Log.debug "change notice to %s: %s" socket_path
              (Printexc.to_string exn)
          end;
          Lwt.return_unit))
    t.sockets

let rec flush t =
  let* () = Lwt_unix.sleep flush_interval in
  let keys = Hashtbl.fold (fun k () acc -> k :: acc) t.pending [] in
  Hashtbl.reset t.pending;
  if keys = [] then begin
    t.scheduled <- false;
    Lwt.return_unit
  end
  else
    let* () = Lwt_list.iter_s (post t) (chunks max_batch keys) in
    flush t

let send ~domain ~sockets key =
  let t = for_domain ~domain ~sockets in
  if t.sockets <> [] then begin
    Hashtbl.replace t.pending key ();
    if not t.scheduled then begin
      t.scheduled <- true;
      Lwt.async (fun () -> flush t)
    end
  end
