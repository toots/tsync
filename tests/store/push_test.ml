(* frontends/http-proxy.md §A4.7, over a stub APNs. *)

open Tsync_core
open Tsync_store
open Tsync_http
module P = Tsync_http_proxy.Store_server
module Push = Tsync_http_proxy.Push
module Dsa = Mirage_crypto_ec.P256.Dsa

let p fmt =
  Printf.ksprintf
    (fun s ->
      print_string s;
      flush stdout)
    fmt

let secret = String.make 40 's'
let d = Domain_name.v "d"
let author = String.make 32 'a'
let others = [String.make 32 'b'; String.make 32 'c']
let token client = "70" ^ String.sub client 0 4

(* What the stub received, and what it answers per token. *)
let sent = ref []
let answers = Hashtbl.create 4
let lock = Mutex.create ()

let stub ~url ~headers body =
  Mutex.protect lock (fun () -> sent := (url, headers, body) :: !sent);
  let tok = List.nth (String.split_on_char '/' url) 5 in
  match Hashtbl.find_opt answers tok with
    | Some (status, body) -> { Http2.status; body }
    | None -> { Http2.status = 200; body = "" }

let take () =
  Mutex.protect lock (fun () ->
      let s = List.rev !sent in
      sent := [];
      s)

let tokens pushes =
  String.concat " "
    (List.sort compare
       (List.map
          (fun (url, _, _) -> List.nth (String.split_on_char '/' url) 5)
          pushes))

let b64url_decode s =
  Base64.decode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let verifies key jwt =
  match String.split_on_char '.' jwt with
    | [h; c; s] ->
        let signature = b64url_decode s in
        Dsa.verify ~key
          (String.sub signature 0 32, String.sub signature 32 32)
          Digestif.SHA256.(to_raw_string (digest_string (h ^ "." ^ c)))
    | _ -> false

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-push-%d" (Unix.getpid ()))

let refusal f =
  match f () with
    | _ -> "accepted"
    | exception Tsync_config.Config.Invalid m ->
        Re.replace_string (Re.compile (Re.str root)) ~by:"<root>" m

let () =
  Fs.rm_rf root;
  Fs.mkdir_p root;
  let key = X509.Private_key.generate ~seed:"push test key" `P256 in
  let public =
    match key with `P256 k -> Dsa.pub_of_priv k | _ -> assert false
  in
  let key_file perm =
    let f = Filename.concat root (Printf.sprintf "key-%o.p8" perm) in
    Fs.replace ~perm f (X509.Private_key.encode_pem key);
    Unix.chmod f perm;
    f
  in
  let options key =
    {
      Push.key;
      key_id = "KEYID12345";
      team_id = "TEAM123456";
      topic = "app.pushkit.fileprovider";
    }
  in
  let params =
    {
      Push.default_params with
      coalesce = 0.5;
      apns =
        (fun e ->
          match e with
            | `Development -> "https://sandbox.test"
            | `Production -> "https://apns.test");
    }
  in
  let dir = Filename.concat root "push" in
  let counted = Hashtbl.create 4 in
  let count name =
    Mutex.protect lock (fun () ->
        Hashtbl.replace counted name
          (1 + Option.value ~default:0 (Hashtbl.find_opt counted name)))
  in
  let make ?(params = params) () =
    Push.create ~params ~count ~dir (options (key_file 0o600)) [d]
  in
  p "== startup\n";
  p "a build without push: %s\n" (refusal make);
  Http2.register ~name:"stub" stub;
  p "a key others can read: %s\n"
    (refusal (fun () -> Push.create ~count ~dir (options (key_file 0o644)) [d]));
  p "a missing key: %s\n"
    (refusal (fun () ->
         Push.create ~count ~dir (options (Filename.concat root "none.p8")) [d]));
  Rt.run_sync (fun () ->
      let local name = Local.create ~name (Filename.concat root name) in
      let route name =
        {
          P.name;
          domain = Domain_name.v name;
          secret;
          read_only = false;
          domain_settings =
            {
              chunk = 4096;
              symlinks = `Skip;
              lease = 20.;
              quarantine = 200.;
              settle = 420.;
              entry_commands = 64;
              projector = None;
              extensions = [];
              vault_lock = Vault_lock.none;
            };
          store = local name;
          share = `Off;
          wake = ignore;
        }
      in
      let push = ref None in
      let serve ?push:make routes =
        let server =
          Server.serve
            [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)]
            (P.handle (P.create ?push:make routes))
        in
        match Server.addresses server with
          | [ADDR_INET (_, port)] -> Printf.sprintf "http://127.0.0.1:%d" port
          | _ -> assert false
      in
      let client url =
        (Option.get (Driver.find "http-proxy")).create ~admission:Uplink.none
          ~domain:d ~name:"proxy"
          [("url", Field_spec.S url); ("secret", Field_spec.S secret)]
      in
      let registration client =
        Printf.sprintf
          {|{"client":"%s","token":"%s","environment":"%s","domain":"d-fp"}|}
          client (token client)
          (if client = author then "production" else "development")
      in
      let register s client =
        (Option.get s.Store.push_register) (registration client)
      in
      p "\n== a listener without pushes\n";
      let plain = client (serve [route "d"]) in
      p "push-register: %b\n" (register plain author);
      let s =
        client
          (serve
             ~push:(fun counter ->
               let count n =
                 counter n;
                 count n
               in
               let t =
                 Push.create ~params ~count ~dir (options (key_file 0o600)) [d]
               in
               push := Some t;
               t)
             [route "d"])
      in
      let push = Option.get !push in
      p "\n== registrations\n";
      List.iter
        (fun c -> p "push-register %s: %b\n" (token c) (register s c))
        (author :: others);
      p "a malformed body: %s\n"
        (Contract.kind_of (fun () ->
             (Option.get s.push_register) {|{"client":"x"}|}));
      p "registered: %d\n" (List.length (Push.registrations push d));
      let entry = ref 0 in
      let commit by =
        incr entry;
        let k =
          Key.v (Printf.sprintf "tsync/d/log/000000000000/%016d" !entry)
        in
        ignore
          (s.put_if_absent k
             (Bigstring.of_string
                (Printf.sprintf
                   {|{"v":1,"author":"%s","commands":[{"file":["3f9a0c1b2d4e-40a","f%d"],"before":"8f3a0c1b2d4e5f60-1b2d4e5f608f3a0c","after":null}]}|}
                   by !entry)))
      in
      p "\n== a change\n";
      commit author;
      Rt.sleep 0.2;
      let pushes = take () in
      p "pushed to: %s\n" (tokens pushes);
      (match
         List.find_opt
           (fun (u, _, _) ->
             String.ends_with ~suffix:(token (List.hd others)) u)
           pushes
       with
        | Some (url, headers, body) ->
            p "url: %s\n" url;
            List.iter
              (fun h -> p "%s: %s\n" h (List.assoc h headers))
              ["apns-push-type"; "apns-topic"];
            p "body: %s\n" body;
            let jwt =
              let a = List.assoc "authorization" headers in
              String.sub a 7 (String.length a - 7)
            in
            (match String.split_on_char '.' jwt with
              | h :: c :: _ ->
                  p "jwt header: %s\n" (b64url_decode h);
                  p "jwt issuer: %s\n"
                    Yojson.Safe.Util.(
                      member "iss" (Yojson.Safe.from_string (b64url_decode c))
                      |> to_string)
              | _ -> p "jwt: malformed\n");
            p "signature verifies: %b\n" (verifies public jwt);
            p "the token with other claims verifies: %b\n"
              (verifies public
                 (match String.split_on_char '.' jwt with
                   | [h; _; sg] ->
                       String.concat "."
                         [
                           h;
                           Base64.encode_string ~pad:false
                             ~alphabet:Base64.uri_safe_alphabet
                             {|{"iss":"OTHER","iat":0}|};
                           sg;
                         ]
                   | _ -> jwt))
        | None -> p "no push to %s\n" (token (List.hd others)));
      p "\n== ten changes within the interval\n";
      (* Straight to the listener's push, so that all ten fall in one
         interval however long a commit takes. *)
      for _ = 1 to 10 do
        Push.changed push d ~author
      done;
      Rt.sleep 0.8;
      p "pushed to: %s\n" (tokens (take ()));
      p "\n== the author's change of its own\n";
      Rt.sleep 0.6;
      commit (List.hd others);
      Rt.sleep 0.2;
      p "pushed to: %s\n" (tokens (take ()));
      p "\n== a token APNs says is gone\n";
      Hashtbl.replace answers
        (token (List.nth others 1))
        (410, {|{"reason":"Unregistered"}|});
      Rt.sleep 0.6;
      commit author;
      Rt.sleep 0.2;
      p "pushed to: %s\n" (tokens (take ()));
      p "registered: %s\n"
        (String.concat " "
           (List.sort compare
              (List.map
                 (fun (r : Push.registration) -> r.token)
                 (Push.registrations push d))));
      p "\n== a restart\n";
      let again = make () in
      p "registered: %s\n"
        (String.concat " "
           (List.sort compare
              (List.map
                 (fun (r : Push.registration) -> r.token)
                 (Push.registrations again d))));
      p "\n== a registration not renewed\n";
      let aged = make ~params:{ params with max_age = 0.1 } () in
      Rt.sleep 0.2;
      Push.changed aged d ~author;
      Rt.sleep 0.2;
      p "pushed to: %s\n" (tokens (take ()));
      p "registered: %d\n" (List.length (Push.registrations aged d)));
  p "\n== counters\n";
  List.iter
    (fun n ->
      p "%s: %d\n" n (Option.value ~default:0 (Hashtbl.find_opt counted n)))
    ["pushSent"; "pushFailed"; "pushDropped"];
  Fs.rm_rf root
