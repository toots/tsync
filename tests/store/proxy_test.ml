open Tsync_core
open Tsync_store
open Tsync_http
module P = Tsync_http_proxy.Store_server

let p = Contract.p
let secret = String.make 40 's'
let d = Domain_name.v "d"
let ro_secret = String.make 40 'r'

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-proxy-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let local name = Local.create ~name (Filename.concat root name) in
      let route ?(read_only = false) ?(secret = secret) name domain store =
        {
          P.name;
          domain = Domain_name.v domain;
          secret;
          read_only;
          chunk_size = Some 4096;
          store;
          share = None;
        }
      in
      let proxy =
        P.create ~max_concurrent:4
          [
            route "d" "d" (local "d");
            route "ro" "ro" ~read_only:true ~secret:ro_secret (local "ro");
          ]
      in
      let server =
        Server.serve
          [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)]
          (P.handle proxy)
      in
      let url =
        match Server.addresses server with
          | [ADDR_INET (_, port)] -> Printf.sprintf "http://127.0.0.1:%d" port
          | _ -> assert false
      in
      let client ?(secret = secret) domain =
        (Option.get (Driver.find "http-proxy")).create ~admission:Uplink.none
          ~domain:(Domain_name.v domain) ~name:("proxy-" ^ domain)
          [("url", Field_spec.S url); ("secret", Field_spec.S secret)]
      in
      let s = client "d" in
      Contract.run s;
      p "\n== http-proxy (backends/http-proxy §12)\n";
      let kind f = Contract.kind_of f in
      let ro = client ~secret:ro_secret "ro" in
      p "read-only put: %s\n"
        (kind (fun () -> Contract.put ro (Key.v "tsync/ro/x") "x"));
      p "read-only get of an absent key: %s\n"
        (Contract.show (Contract.get ro (Key.v "tsync/ro/x")));
      let wrong = client ~secret:(String.make 40 'w') "d" in
      p "wrong secret: %s\n"
        (kind (fun () -> Contract.get wrong (Key.v "tsync/d/a")));
      let unserved = client "other" in
      p "unserved domain get_opt: %s\n"
        (kind (fun () -> Contract.get unserved (Key.v "tsync/other/a")));
      p "unserved domain head: %s\n"
        (kind (fun () -> unserved.head_opt (Key.v "tsync/other/a")));
      p "a key of another route: %s\n"
        (kind (fun () -> Contract.get s (Key.v "tsync/ro/x")));
      let caps = s.capabilities (Key.domain_prefix d) in
      p "capabilities: chunk %s, concurrency %s, verified %b\n"
        (Option.fold ~none:"none" ~some:string_of_int caps.chunk_size)
        (Option.fold ~none:"none" ~some:string_of_int caps.max_concurrency)
        caps.verified;
      p "get_many across pages: %d answers\n"
        (List.length
           (Option.get s.get_many
              (List.init 2500 (fun i ->
                   Key.v (Printf.sprintf "tsync/d/many/%d" i)))));
      Contract.put s (Key.v "tsync/d/manifests/x/f") "hi";
      p "list_many: %d folders\n"
        (List.length
           (Option.get s.list_many [Key.prefix "tsync/d/manifests/x/"]));
      p "== watch\n";
      let cursor = Key.cursor d in
      Contract.put s cursor "one";
      let t0 = Rt.now () in
      s.watch cursor None;
      p "behind: returned at once %b\n" (Rt.now () -. t0 < 1.);
      let waiter =
        Rt.async (fun () ->
            let t0 = Rt.now () in
            s.watch cursor (Some "one");
            Rt.now () -. t0)
      in
      Rt.sleep 0.5;
      Contract.put s cursor "two";
      let took = Rt.Promise.await waiter in
      p "a change wakes the watch: %b\n" (took < 5.);
      let held =
        Rt.async (fun () -> try s.watch cursor (Some "two") with _ -> ())
      in
      Rt.sleep 0.5;
      let t0 = Rt.now () in
      Stop.request ();
      Server.close server;
      p "a stop answers a held watch, closing in under 2s: %b\n"
        (Rt.now () -. t0 < 2.);
      ignore (Rt.Promise.peek held))
