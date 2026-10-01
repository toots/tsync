open Tsync_core

type raw_entry = {
  name : string;
  size : int;
  last_modified : float;
  etag : string option;
}

type verbs = {
  put : Key.t -> Bigstring.t -> unit;
  put_if_absent : Key.t -> Bigstring.t -> Store.claim;
  get_opt : Key.t -> Bigstring.t option;
  get_range : Key.t -> int -> int -> Bigstring.t option;
  head_opt : Key.t -> Store.entry option;
  delete : Key.t -> bool;
  delete_page : Key.t list -> unit;
  copy : Key.t -> Key.t -> unit;
  list_page :
    prefix:Key.prefix ->
    token:string option ->
    max:int option ->
    raw_entry list * string option;
}

let page = 1000

let status_failure ~op ?retry_after ?(body = "") status =
  let reason =
    Printf.sprintf "%s: HTTP %d%s" op status
      (if body = "" then "" else ": " ^ body)
  in
  let kind =
    match status with
      | 429 -> Fail.Load
      | 503 when retry_after <> None || Text.contains body "SlowDown" ->
          Fail.Load
      | 409 when Text.contains body "onflict" -> Fail.Load
      | s when s >= 500 -> Fail.Link
      | 401 | 403 -> Fail.Denied
      | _ -> Fail.Refused
  in
  Fail.make ?retry_after ~op kind reason

let per_key_failure ~op ~code ~key =
  let kind =
    match code with
      | "InternalError" | "SlowDown" | "ServiceUnavailable" -> Fail.Load
      | _ -> Fail.Refused
  in
  Fail.make ~op kind (Printf.sprintf "%s: %s refused: %s" op key code)

(* A listing is complete or it is a failure: every page is fetched, then sorted
   and cut, never merged with anything else. *)
let list_all v ~store ?max_keys prefix =
  let rec pages token acc count =
    let entries, next = v.list_page ~prefix ~token ~max:max_keys in
    let acc = entries :: acc and count = count + List.length entries in
    match (next, max_keys) with
      | Some _, Some m when count >= m -> List.concat (List.rev acc)
      | Some t, _ -> pages (Some t) acc count
      | None, _ -> List.concat (List.rev acc)
  in
  let entries =
    pages None [] 0
    |> List.filter_map (fun (e : raw_entry) ->
        Option.map
          (fun key ->
            {
              Store.key;
              size = e.size;
              last_modified = e.last_modified;
              etag = e.etag;
            })
          (Store.listed store e.name))
    |> List.sort (fun (a : Store.entry) b -> Key.compare a.key b.key)
  in
  match max_keys with
    | Some m -> List.filteri (fun i _ -> i < m) entries
    | None -> entries

let rec chunks n = function
  | [] -> []
  | l ->
      let rec take k acc = function
        | x :: rest when k > 0 -> take (k - 1) (x :: acc) rest
        | rest -> (List.rev acc, rest)
      in
      let a, rest = take n [] l in
      a :: chunks n rest

let make ~name ~admission ?share_url v =
  let health = Health.create name in
  let traffic = Store.new_traffic () in
  let ladder op f = Retry.ladder ~health ~op f in
  let up n = ignore (Atomic.fetch_and_add traffic.uploaded n) in
  let down = function
    | Some s ->
        ignore (Atomic.fetch_and_add traffic.downloaded (Bigstring.length s))
    | None -> ()
  in
  Store.checked
    {
      Store.name;
      put =
        (fun ?(mode = Store.Wait) k body ->
          ladder "put" (fun () ->
              Uplink.admitted admission mode (Bigstring.length body) (fun () ->
                  up (Bigstring.length body);
                  v.put k body)));
      put_if_absent =
        (fun k body ->
          ladder "put_if_absent" (fun () ->
              let r =
                Uplink.admitted admission Wait (Bigstring.length body)
                  (fun () ->
                    up (Bigstring.length body);
                    v.put_if_absent k body)
              in
              (match r with Held b -> down (Some b) | Won -> ());
              r));
      get_opt =
        (fun k ->
          ladder "get" (fun () ->
              let r = v.get_opt k in
              down r;
              r));
      get_range =
        (fun k off len ->
          ladder "get_range" (fun () ->
              let r = v.get_range k off len in
              (match r with
                | Some s when Bigstring.length s > len ->
                    Fail.corrupt "%s: asked %d bytes of %s, got %d" name len
                      (Key.to_string k) (Bigstring.length s)
                | _ -> ());
              down r;
              r));
      head_opt = (fun k -> ladder "head" (fun () -> v.head_opt k));
      delete = (fun k -> ladder "delete" (fun () -> v.delete k));
      delete_multi =
        (fun keys ->
          List.iter
            (fun p -> ladder "delete_multi" (fun () -> v.delete_page p))
            (chunks page keys));
      copy = (fun src dst -> ladder "copy" (fun () -> v.copy src dst));
      list_prefix =
        (fun ?max_keys prefix ->
          ladder "list" (fun () -> list_all v ~store:name ?max_keys prefix));
      watch = (fun _ _ -> Stop.sleep Store.watch_interval);
      get_many = None;
      list_many = None;
      bucket_functions = true;
      capabilities = (fun _ -> { Store.no_caps with share_url });
      fast_read = false;
      local_path = None;
      health;
      traffic = Some traffic;
    }
