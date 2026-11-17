(* 08 §3.7: a list_dir page is chosen from the folder's names and reads only
   the entries it serves; an unreadable child is skipped and paging goes on. *)

open Tsync_core
open Tsync_owner

let p fmt = Printf.printf (fmt ^^ "\n%!")
let root = Printf.sprintf "/tmp/tsync-list-pages-%d" (Unix.getpid ())
let home = Filename.concat root "home"

let () =
  Fs.rm_rf root;
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

let config =
  Tsync_config.Config.of_string
    (Printf.sprintf
       {|{"name":"test","domains":[
  {"name":"docs","symlinks":"keep","versioning":true,"extensions":[],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
       root)

let write h name =
  let staging = Filename.concat home ("staging-" ^ name) in
  Out_channel.with_open_bin staging (fun oc -> output_string oc name);
  ignore
    (Handler.call h
       (Protocol.Write
          {
            at = Child { parent_ref = "root"; name };
            staging;
            base = None;
            exclusive = true;
            aside = false;
            await = false;
            created = None;
          }))

(* The mirror entry of a published file: its manifest, named by its leaf. *)
let rec find_entry dir leaf =
  List.find_map
    (fun n ->
      let p = Filename.concat dir n in
      if n = leaf then Some p
      else if Sys.is_directory p then find_entry p leaf
      else None)
    (List.sort compare (Array.to_list (Sys.readdir dir)))

let pages h =
  let rec go after =
    let page =
      Handler.call h
        (Protocol.List_dir { dir = Rel ""; after; limit = Some 2; pull = `Auto })
    in
    p "after %-6s [%s] next %s"
      (Option.value ~default:"-" after)
      (String.concat " "
         (List.map (fun (r : Protocol.row) -> r.name) page.items))
      (Option.value ~default:"-" page.next);
    Option.iter (fun n -> go (Some n)) page.next
  in
  go None

let () =
  let dom = List.hd config.Tsync_config.Config.domains in
  Rt.run_sync (fun () ->
      Owner.one_shot ~what:"test" config dom (fun h ->
          List.iter (write h) ["a"; "b"; "c"; "d"];
          ignore (Handler.call h (Protocol.Sync { full = false }));
          let c =
            Option.get (find_entry (Tsync_config.Paths.cache_root ()) "c")
          in
          Out_channel.with_open_bin c (fun oc -> output_string oc "garbage");
          write h "e";
          pages h));
  Fs.rm_rf root
