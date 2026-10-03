(* The directory watch (spec 01 §14) and the local store's watch on it
   (backends/local §8): woken by a change, not by a temporary file, dropped
   when the directory goes; a watch returns soon after the key changes. *)

open Tsync_core
open Tsync_store

let p fmt = Printf.printf fmt
let d = Domain_name.v "d"

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-watch-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let dir = Filename.concat root "dir" in
  Fs.mkdir_p dir;
  let write name =
    Out_channel.with_open_bin (Filename.concat dir name) (fun oc ->
        output_string oc "x")
  in
  Rt.run_sync (fun () ->
      let after delay f =
        Rt.spawn (fun () ->
            Rt.sleep delay;
            f ())
      in
      let timed f =
        let t0 = Rt.now () in
        let r = f () in
        (r, Rt.now () -. t0)
      in
      (* Events left from the case before, such as a write's close after its
         create woke the wait, are drained so each case sees its own. *)
      let rec quiet w =
        if Dir_watch.wait w ~timeout:0.3 <> `Timeout then quiet w
      in
      let show = function
        | `Changed -> "changed"
        | `Gone -> "gone"
        | `Timeout -> "timeout"
      in
      match Dir_watch.open_ dir with
        | None -> p "no directory watch on this platform\n"
        | Some w ->
            p "nothing happens: %s\n" (show (Dir_watch.wait w ~timeout:0.3));
            quiet w;
            after 0.1 (fun () -> write (Names.temp_name ()));
            p "a temporary file only: %s\n"
              (show (Dir_watch.wait w ~timeout:0.5));
            quiet w;
            after 0.1 (fun () -> write "real");
            let r, t = timed (fun () -> Dir_watch.wait w ~timeout:5.) in
            p "a file written: %s within a second: %b\n" (show r) (t < 1.);
            quiet w;
            after 0.1 (fun () ->
                let tmp = Filename.concat dir (Names.temp_name ()) in
                Out_channel.with_open_bin tmp (fun oc -> output_string oc "y");
                Unix.rename tmp (Filename.concat dir "renamed"));
            let r, t = timed (fun () -> Dir_watch.wait w ~timeout:5.) in
            p "a rename into place: %s within a second: %b\n" (show r) (t < 1.);
            List.iter
              (fun n -> Sys.remove (Filename.concat dir n))
              (Array.to_list (Sys.readdir dir));
            quiet w;
            after 0.1 (fun () -> Unix.rmdir dir);
            p "the directory removed: %s\n"
              (show (Dir_watch.wait w ~timeout:5.));
            Dir_watch.close w;
            p "a missing directory can be watched: %b\n"
              (Dir_watch.open_ dir <> None);
            let store =
              Local.create ~name:"main" (Filename.concat root "store")
            in
            let key = Key.cursor d in
            store.put key (Bigstring.of_string "one");
            let last = Store.token (store.get_opt key) in
            after 0.3 (fun () -> store.put key (Bigstring.of_string "two"));
            let (), t = timed (fun () -> store.watch key last) in
            p
              "a store watch returns soon after the key changed: %b (interval \
               %.0f s)\n"
              (t < 1.5) Store.watch_interval);
  Fs.rm_rf root
