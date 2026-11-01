open Tsync_core
open Tsync_config
open Tsync_ipc
open Tsync_owner
open Tsync_menu
module M = Menu_model

(* linux-tray.md §10. *)
let poll_interval = 3.
let status_deadline = 1.5
let stats_deadline = 4.
let pause_deadline = 5.
let stats_debounce = 1.
let unlock_deadline = 120.

type platform = {
  menu : M.t -> unit;
  children : M.action -> M.entry list -> unit;
  marks : (string * string) list -> unit;
  notify : string -> string -> unit;
  copy : string -> (unit, string) result;
  show : folder:bool -> string -> unit;
  ask_secret : title:string -> string -> string option;
  can_ask : unit -> (unit, string) result;
  code_domains : string list -> string list;
}

type domain = { name : string; socket : string; configured : string option }

(* [lock] guards every mutable field; it is never held across a wait. *)
type t = {
  platform : platform;
  quit : string;
  lock : Mutex.t;
  mutable domains : domain list;
  mutable reported_mounts : (string * string) list;
  mutable stats_started : float;
  mutable unlocking : bool;
  mutable code_domains : string list;  (** at the last refresh (§6.5) *)
  refreshing : Rt.Fmutex.t;
  finished : int Rt.Promise.t;
}

let create ~quit platform =
  {
    platform;
    quit;
    lock = Mutex.create ();
    domains = [];
    reported_mounts = [];
    stats_started = neg_infinity;
    unlocking = false;
    code_domains = [];
    refreshing = Rt.Fmutex.create ();
    finished = Rt.Promise.create ();
  }

let finished t = t.finished
let locked t f = Mutex.protect t.lock f

let mount_point t name =
  locked t (fun () ->
      match List.assoc_opt name t.reported_mounts with
        | Some m -> Some m
        | None ->
            Option.bind
              (List.find_opt (fun d -> d.name = name) t.domains)
              (fun d -> d.configured))

(* One request to every domain's owner at the same time, in the owner's own
   encoding. *)
let ask_all t ~deadline request =
  let domains = locked t (fun () -> t.domains) in
  let request = Protocol.encode request in
  List.combine domains
    (Rt.map_concurrently (fun d -> Ipc.ask ~deadline d.socket request) domains)

(* A config that cannot be used is no domains, whatever the reason (§5.2). *)
let configured_domains () =
  let none reason =
    Log.once ("tray-config:" ^ reason) Log.Warn "tray: no domains: %s" reason;
    []
  in
  match Paths.read_config ~interactive:false () with
    | None -> none ("no config at " ^ Paths.config_file ())
    | Some text -> (
        match Config.of_string text with
          | config ->
              List.map
                (fun (d : Config.domain) ->
                  {
                    name = Domain_name.to_string d.name;
                    socket = Paths.owner_socket d.name;
                    configured = Mounts.configured d;
                  })
                config.domains
          | exception Config.Invalid reason -> none reason)
    | exception e -> none (Fail.classify e).reason

let string_field name = function
  | `Assoc l -> (
      match List.assoc_opt name l with Some (`String s) -> Some s | _ -> None)
  | _ -> None

(* §6.5: whether a status reply lists totp among the extensions in force. *)
let lists_totp = function
  | `Assoc l -> (
      match List.assoc_opt "extensions" l with
        | Some (`List e) -> List.mem (`String "totp") e
        | _ -> false)
  | _ -> false

let refresh t =
  Rt.Fmutex.with_lock t.refreshing @@ fun () ->
  let domains = try configured_domains () with _ -> [] in
  let replies =
    Rt.map_concurrently
      (fun d ->
        Ipc.ask ~deadline:status_deadline d.socket (Protocol.encode Status))
      domains
  in
  let answers =
    List.map2
      (fun d reply -> (d, reply, Option.bind reply M.status_of_json))
      domains replies
  in
  let codes =
    t.platform.code_domains
      (List.filter_map
         (fun (d, reply, status) ->
           match (status, reply) with
             | Some _, Some reply when lists_totp reply -> Some d.name
             | _ -> None)
         answers)
  in
  let menu =
    M.render ~quit:t.quit ~codes
      (List.map (fun (d, _, status) -> (d.name, status)) answers)
  in
  locked t (fun () ->
      t.domains <- domains;
      t.code_domains <- codes;
      t.reported_mounts <-
        List.filter_map
          (fun (d, reply, status) ->
            match (status, Option.bind reply (string_field "mount")) with
              | Some _, Some mount -> Some (d.name, mount)
              | _ -> None)
          answers);
  t.platform.menu menu

let poll t =
  let rec loop due =
    (try refresh t
     with e when not (Rt.is_cancelled e) ->
       Log.warn "tray: refresh failed: %s" (Printexc.to_string e));
    let now = Rt.now () in
    let due = Float.max (due +. poll_interval) now in
    Rt.sleep (due -. now);
    loop due
  in
  loop (Rt.now ())

let domain_named t name =
  locked t (fun () -> List.find_opt (fun d -> d.name = name) t.domains)

(* The owner's typed answer to one request, or its failure. *)
let ask_domain ~deadline d request =
  match Ipc.ask ~deadline d.socket (Protocol.encode request) with
    | None -> Error "tsync is not answering"
    | Some reply -> (
        match Protocol.decode_reply request reply with
          | answer -> Ok answer
          | exception Fail.E f -> Error f.reason)

(* vault §8.1: a vault's mark is its icon, else its colour's glyph. *)
let mark d =
  match ask_domain ~deadline:stats_deadline d (Vault_status `Auto) with
    | Ok { appearance = Some { icon = Some png; _ }; _ } -> Some png
    | Ok { appearance = Some { color; _ }; _ } -> Mark.glyph color
    | _ -> None

let code_domains t =
  locked t (fun () ->
      List.filter (fun d -> List.mem d.name t.code_domains) t.domains)

let fetch_codes t domains =
  if domains <> [] then (
    let answers =
      Rt.map_concurrently
        (fun d ->
          let codes =
            M.codes_of_json
              (Ipc.ask ~deadline:stats_deadline d.socket
                 (Protocol.encode (Totp_list { filter = None; pull = `Auto })))
          in
          (d.name, codes, mark d))
        domains
    in
    t.platform.marks
      (List.filter_map
         (fun (domain, _, mark) -> Option.map (fun m -> (domain, m)) mark)
         answers);
    t.platform.children Show_codes
      (M.codes ~add:false
         (List.map (fun (domain, codes, _) -> (domain, codes)) answers)))

let opened t =
  let due =
    locked t (fun () ->
        let now = Rt.now () in
        if now -. t.stats_started < stats_debounce then false
        else (
          t.stats_started <- now;
          true))
  in
  if due then (
    Rt.spawn ~name:"tray stats" (fun () ->
        t.platform.children Show_stats
          (M.stats
             (List.filter_map
                (fun (_, reply) -> Option.bind reply M.stats_of_json)
                (ask_all t ~deadline:stats_deadline (Stats [])))));
    (* §6.5: rows from an earlier opening are never shown again, so they are
       gone before the platform can show the submenu. *)
    let domains = code_domains t in
    if domains <> [] then t.platform.children Show_codes M.codes_placeholder;
    Rt.spawn ~name:"tray codes" (fun () -> fetch_codes t domains))

(* security-model §10.6: the code is never logged and the clipboard never
   cleared. *)
let copy_code t domain id =
  match domain_named t domain with
    | None -> ()
    | Some d -> (
        match ask_domain ~deadline:stats_deadline d (Totp_code id) with
          | Error reason -> t.platform.notify "The code was not copied" reason
          | Ok { code; _ } -> (
              match t.platform.copy code with
                | Ok () -> ()
                | Error reason ->
                    t.platform.notify "The code was not copied" reason))

(* §6.5: [sentence] is the owner's word on the previous attempt. *)
let rec unlock_dialogs ?sentence ~enrolled t d =
  let title = "Unlock " ^ d.name in
  let above text =
    match sentence with Some s -> s ^ "\n\n" ^ text | None -> text
  in
  match
    t.platform.ask_secret ~title
      (above ("The passphrase of " ^ d.name ^ "'s vault"))
  with
    | None -> ()
    | Some passphrase -> (
        let secret_key =
          if enrolled then Some ""
          else
            t.platform.ask_secret ~title
              "This machine also needs the vault's secret key"
        in
        match secret_key with
          | None -> ()
          | Some secret_key -> (
              let request =
                Protocol.Vault_unlock
                  {
                    passphrase;
                    secret_key =
                      (if secret_key = "" then None else Some secret_key);
                  }
              in
              match
                Ipc.ask ~deadline:unlock_deadline d.socket
                  (Protocol.encode request)
              with
                | None ->
                    t.platform.notify
                      ("Unlocking " ^ d.name ^ " failed")
                      "tsync is not answering"
                | Some reply -> (
                    match Protocol.failure_of_reply reply with
                      | None -> ()
                      | Some { kind = Denied | Invalid; reason; _ } ->
                          unlock_dialogs ~sentence:reason ~enrolled t d
                      | Some f ->
                          t.platform.notify
                            ("Unlocking " ^ d.name ^ " failed")
                            f.reason)))

let unlock t domain =
  let start =
    locked t (fun () ->
        if t.unlocking then false
        else (
          t.unlocking <- true;
          true))
  in
  if start then
    Fun.protect
      ~finally:(fun () -> locked t (fun () -> t.unlocking <- false))
      (fun () ->
        match domain_named t domain with
          | None -> ()
          | Some d -> (
              let run_cli = "Run tsync vault unlock in a terminal." in
              match
                ask_domain ~deadline:stats_deadline d (Vault_status `Auto)
              with
                | Error reason ->
                    t.platform.notify
                      ("Cannot unlock " ^ domain)
                      (reason ^ " " ^ run_cli)
                | Ok status -> (
                    match t.platform.can_ask () with
                      | Error why ->
                          t.platform.notify
                            ("Cannot unlock " ^ domain)
                            (why ^ " " ^ run_cli)
                      | Ok () -> unlock_dialogs ~enrolled:status.enrolled t d)))

let set_paused t paused =
  List.iter
    (fun (d, reply) ->
      let refused why =
        Log.warn "tray: %s did not %s: %s" d.name
          (if paused then "hold" else "resume")
          why
      in
      match Option.map Protocol.failure_of_reply reply with
        | None -> refused "no answer"
        | Some None -> ()
        | Some (Some failure) -> refused failure.reason)
    (ask_all t ~deadline:pause_deadline (Pause paused));
  refresh t

let run_action t : M.action -> unit = function
  | Nothing | Show_stats | Show_codes | Add_code _ -> ()
  | Copy_code { domain; id } -> copy_code t domain id
  | Unlock domain -> unlock t domain
  | Quit -> ignore (Rt.Promise.try_resolve t.finished 0)
  | Set_paused paused -> set_paused t paused
  | Open_folder name ->
      Option.iter (t.platform.show ~folder:true) (mount_point t name)
  | Reveal { domain; rel } ->
      Option.iter
        (fun m -> t.platform.show ~folder:false (Filename.concat m rel))
        (mount_point t domain)
