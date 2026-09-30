open Tsync_core
open Tsync_store

let cursor_interval = 2.

type t = {
  domain : Domain_name.t;
  store : Store.t;
  m : Mutex.t;
  mutable pending : Entry_key.t option;
  mutable last_publish : float;
  mutable armed : bool;
  publish_m : Rt.Fmutex.t;
}

let create domain store =
  {
    domain;
    store;
    m = Mutex.create ();
    pending = None;
    last_publish = neg_infinity;
    armed = false;
    publish_m = Rt.Fmutex.create ();
  }

(* 03 §2.4: every object under the prefix whose last segment is an entry key
   is an entry, wherever it sits; a key listed twice is one entry. *)
let list_entries t =
  let seen = Hashtbl.create 256 in
  List.filter_map
    (fun (e : Store.entry) ->
      match Entry_key.parse (Key.to_string e.key) with
        | Some k when not (Hashtbl.mem seen (Entry_key.to_string k)) ->
            Hashtbl.replace seen (Entry_key.to_string k) ();
            Some (k, e.key)
        | _ -> None)
    (t.store.list_prefix (Key.journal t.domain))
  |> List.sort (fun (a, _) (b, _) -> Entry_key.compare a b)

let read_entry t key =
  match t.store.get_opt key with
    | None -> None
    | Some body -> (
        match Op.decode_entry body with
          | Ok ops -> Some ops
          | Error what ->
              Fail.corrupt "journal entry %s: expected %s" (Key.to_string key)
                what)

let entry_exists t k =
  t.store.head_opt (Entry_key.journal_key t.domain k) <> None

let write_entry t k ops =
  t.store.put (Entry_key.journal_key t.domain k) (Op.encode_entry ops)

let cursor_read t =
  match t.store.get_opt (Key.cursor t.domain) with
    | None -> `None
    | Some b -> (
        match Entry_key.parse b with Some k -> `Key k | None -> `Unparsed b)

let cursor_token t = Store.token (t.store.get_opt (Key.cursor t.domain))
let cursor_wait t token = t.store.watch (Key.cursor t.domain) token

let publish_now t k =
  Rt.Fmutex.with_lock t.publish_m (fun () ->
      t.store.put (Key.cursor t.domain) (Entry_key.to_string k);
      Mutex.protect t.m (fun () -> t.last_publish <- Rt.now ()))

let take t =
  Mutex.protect t.m (fun () ->
      let p = t.pending in
      t.pending <- None;
      p)

let flush t =
  match take t with
    | None -> ()
    | Some k -> (
        try publish_now t k
        with e ->
          Log.warn "cursor bump of %s dropped: %s" (Entry_key.to_string k)
            (Printexc.to_string e))

(* wal-and-journal §4.2: one write per interval of the newest key; an older
   key never replaces a newer pending one. *)
let note t k =
  let arm =
    Mutex.protect t.m (fun () ->
        (match t.pending with
          | Some p when Entry_key.compare p k >= 0 -> ()
          | _ -> t.pending <- Some k);
        if t.armed then None
        else (
          t.armed <- true;
          Some (max 0. (cursor_interval -. (Rt.now () -. t.last_publish)))))
  in
  Option.iter
    (fun delay ->
      Rt.spawn ~name:"cursor" (fun () ->
          (try Rt.sleep delay with _ -> ());
          Mutex.protect t.m (fun () -> t.armed <- false);
          flush t))
    arm

let bump t k =
  let due =
    Mutex.protect t.m (fun () -> Rt.now () -. t.last_publish >= cursor_interval)
  in
  if due then (
    Mutex.protect t.m (fun () ->
        match t.pending with
          | Some p when Entry_key.compare p k <= 0 -> t.pending <- None
          | _ -> ());
    try publish_now t k
    with e ->
      Log.warn "cursor bump of %s dropped: %s" (Entry_key.to_string k)
        (Printexc.to_string e))
  else note t k
