(* The shared socket of the macOS service (file-provider §4, §8, §10, §11):
   served with no domain configured, a router-level subscription to every
   domain, the menu, and transfer paths checked by path rules alone. Run once
   per mode: [empty] or [two]. *)

open Tsync_core
open Tsync_ipc
open Tsync_owner

let p fmt = Printf.printf (fmt ^^ "\n%!")
let mode = Sys.argv.(1)

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-shared-%d" (Unix.getpid ()))

let home = Filename.concat root "home"

(* A short directory: a Unix socket path holds about 100 bytes. *)
let sock_dir = Printf.sprintf "/tmp/tsync-sh-%d" (Unix.getpid ())
let socket = Filename.concat sock_dir "s.sock"

let () =
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Fs.mkdir_p ~perm:0o700 sock_dir;
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

let config =
  Tsync_config.Config.of_string
    (if mode = "empty" then {|{"domains":[]}|}
     else
       Printf.sprintf
         {|{"name":"test","domains":[
  {"name":"docs","symlinks":"keep","versioning":true,"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]},
  {"name":"pics","symlinks":"keep","versioning":true,"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store2"}]}]}|}
         root root)

(* Event ids and folder ids vary from run to run. *)
let rec scrub = function
  | `Assoc l ->
      `Assoc
        (List.map
           (fun (k, v) ->
             match k with
               | "id" -> (k, `String "<n>")
               | "ref" | "parentRef" | "etag" | "contentId" | "mtime" ->
                   (k, `String "<x>")
               | _ -> (k, scrub v))
           l)
  | `List l -> `List (List.map scrub l)
  | j -> j

let mask s =
  List.fold_left
    (fun s dir ->
      let n = String.length dir in
      let b = Buffer.create (String.length s) in
      let rec go i =
        if i >= String.length s then ()
        else if i + n <= String.length s && String.sub s i n = dir then (
          Buffer.add_string b "<dir>";
          go (i + n))
        else (
          Buffer.add_char b s.[i];
          go (i + 1))
      in
      go 0;
      Buffer.contents b)
    s
    [Unix.realpath sock_dir; sock_dir]

let show label j = p "%-28s %s" label (mask (Yojson.Safe.to_string (scrub j)))

let call fields =
  Ipc.call socket (`Assoc (List.map (fun (k, v) -> (k, `String v)) fields))

let rec wait_serving n =
  match call [("action", "ping")] with
    | _ -> ()
    | exception _ when n > 0 ->
        Rt.sleep 0.05;
        wait_serving (n - 1)

(* A frontend whose changes publish one [changed] event, as the File Provider
   host does, without its debounce. *)
let present _ _ ~publish =
  ( {
      Handler.no_hooks with
      changed = (fun _ -> publish Protocol.Changed);
      reannounce = (fun () -> publish Protocol.Changed);
    },
    ignore )

let () =
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      let owner =
        Rt.async (fun () ->
            Owner.run ~present ~shared:true ~roots:[] ~socket config
              config.domains)
      in
      wait_serving 100;
      let c = Ipc.Client.connect socket in
      show "subscribe without a domain"
        (Ipc.Client.request c (`Assoc [("action", `String "subscribe")]));
      let events n =
        List.init n (fun _ ->
            match Ipc.Client.next ~timeout:5. c with
              | Some e ->
                  Option.value ~default:"?" (Ipc.field e "event")
                  ^ " "
                  ^ Option.value ~default:"?" (Ipc.field e "domain")
              | None -> "none")
      in
      let menu () =
        match call [("action", "menu")] with
          | `Assoc l -> (
              match List.assoc_opt "menu" l with Some m -> m | None -> `Null)
          | j -> j
      in
      if mode = "empty" then show "menu" (menu ())
      else (
        p "first events: %s" (String.concat ", " (List.sort compare (events 2)));
        show "menu" (menu ());
        p "menu_stats entries: %b"
          (match call [("action", "menu_stats")] with
            | `Assoc l -> (
                match List.assoc_opt "entries" l with
                  | Some (`List (_ :: _)) -> true
                  | _ -> false)
            | _ -> false);
        show "pause every domain" (call [("action", "pause"); ("arg", "on")]);
        show "menu while held" (menu ());
        show "resume" (call [("action", "pause"); ("arg", "off")]);
        p "paused after resume: %s"
          (String.concat ", "
             (List.map
                (fun d ->
                  d ^ "="
                  ^ Yojson.Safe.to_string
                      (Option.value ~default:`Null
                         (match call [("action", "status"); ("domain", d)] with
                           | `Assoc l -> List.assoc_opt "paused" l
                           | _ -> None)))
                ["docs"; "pics"]));
        show "notify_reset of pics"
          (call [("action", "notify_reset"); ("domain", "pics")]);
        show "full_resync of docs"
          (call [("action", "full_resync"); ("domain", "docs")]);
        p "then: %s" (String.concat ", " (events 2));
        (* Path rules refuse a link anywhere on the way (/tmp is one on
           macOS). *)
        let real = Unix.realpath sock_dir in
        let staging = Filename.concat real "upload" in
        Fs.write_file_for_test staging "bytes";
        show "write, no declared roots"
          (Ipc.call socket
             (`Assoc
                [
                  ("action", `String "write");
                  ("domain", `String "docs");
                  ("parentRef", `String "root");
                  ("name", `String "f.txt");
                  ("staging", `String staging);
                ]));
        let taken = Filename.concat real "taken" in
        Fs.write_file_for_test taken "x";
        show "a dest that exists"
          (Ipc.call socket
             (`Assoc
                [
                  ("action", `String "ensure_cached");
                  ("domain", `String "docs");
                  ("rel", `String "f.txt");
                  ("dest", `String taken);
                ]));
        let link = Filename.concat real "link" in
        Unix.symlink real link;
        show "a dest under a link"
          (Ipc.call socket
             (`Assoc
                [
                  ("action", `String "ensure_cached");
                  ("domain", `String "docs");
                  ("rel", `String "f.txt");
                  ("dest", `String (Filename.concat link "out"));
                ])));
      Ipc.Client.close c;
      show "stop" (call [("action", "stop")]);
      p "exit status %d" (Rt.Promise.await owner));
  (* The owner's stop is process-wide: the runtime takes no more work, so the
     cleanup does not go through it. *)
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s %s" (Filename.quote root)
          (Filename.quote sock_dir)))
