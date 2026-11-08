(* A tray links what tray_core links and nothing more, as the Windows one does:
   its first menu names the domain rather than reporting no config. *)
open Tsync_core

let config =
  {|{"name":"t","domains":[{"name":"photos","versioning":true,"backends":[{"type":"http-proxy","name":"server","role":"main","url":"https://tsync.example.invalid","secret":"0123456789abcdef0123456789abcdef"}],"frontends":["android"]}]}|}

let () =
  Unix.putenv "TSYNC_CONFIG_JSON" config;
  let first = ref None in
  let platform : Tsync_tray_core.Tray_core.platform =
    {
      menu = (fun m -> if !first = None then first := Some m.tooltip);
      children = (fun _ _ -> ());
      marks = None;
      notify = (fun _ _ -> ());
      copy = (fun _ -> Ok ());
      show = (fun ~folder:_ _ -> ());
      ask_secret = (fun ~title:_ _ -> None);
      can_ask = (fun () -> Ok ());
      code_domains = (fun _ -> []);
    }
  in
  Rt.run_sync (fun () ->
      let t = Tsync_tray_core.Tray_core.create ~quit:"Quit" platform in
      ignore (Rt.async (fun () -> Tsync_tray_core.Tray_core.poll t));
      let deadline = Rt.now () +. 10. in
      while !first = None && Rt.now () < deadline do
        Rt.sleep 0.05
      done;
      print_endline (Option.value ~default:"no menu in 10 s" !first);
      exit 0)
