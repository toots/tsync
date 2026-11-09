(* backends/http-proxy §2: the receipt stamp a probe reads, from a server that
   sends it and from one that does not. *)
open Tsync_core
open Tsync_store
open Tsync_http
module P = Tsync_http_proxy.Store_server

let p fmt = Printf.printf (fmt ^^ "\n%!")
let secret = String.make 40 's'
let key = Key.cursor (Domain_name.v "d")
let probe (s : Store.t) = Option.get s.probe key

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-proxy-stamp-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let proxy =
        P.create ~max_concurrent:4
          [
            {
              P.name = "d";
              domain = Domain_name.v "d";
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
              store = Local.create ~name:"d" root;
              share = `Off;
              wake = ignore;
            };
          ]
      in
      let serve strip =
        let server =
          Server.serve
            [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)]
            (fun r read_body ->
              let answer = P.handle proxy r read_body in
              if strip then
                {
                  answer with
                  headers =
                    List.filter
                      (fun (k, _) -> k <> "x-tsync-received")
                      answer.headers;
                }
              else answer)
        in
        let url =
          match Server.addresses server with
            | [ADDR_INET (_, port)] -> Printf.sprintf "http://127.0.0.1:%d" port
            | _ -> assert false
        in
        ( server,
          (Option.get (Driver.find "http-proxy")).create ~admission:Uplink.none
            ~domain:(Domain_name.v "d") ~name:"proxy"
            [("url", Field_spec.S url); ("secret", Field_spec.S secret)] )
      in
      let server, s = serve false in
      p "== a server that stamps";
      (match (probe s, probe s) with
        | Some a, Some b ->
            p "  stamped, absent key included: true";
            p "  one epoch across answers: %b" (a.epoch = b.epoch);
            p "  epoch is 16 hex digits: %b"
              (String.length a.epoch = 16
              && String.for_all
                   (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
                   a.epoch);
            p "  received after it was written, on one machine's clock: %b"
              (a.at >= a.sent -. 1e-6 && a.at -. a.sent < 1.);
            p "  later probes read later: %b" (b.sent > a.sent && b.at > a.at)
        | _ -> p "  stamped: false");
      Server.close server;
      let old, s = serve true in
      p "== a server without the stamp";
      p "  probe answers none: %b" (probe s = None);
      Server.close old);
  Fs.rm_rf root
