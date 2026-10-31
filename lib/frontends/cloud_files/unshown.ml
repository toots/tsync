open Tsync_core

type t = { m : Mutex.t; seen : (string, unit) Hashtbl.t }

let create () = { m = Mutex.create (); seen = Hashtbl.create 16 }

let note t ~ref_ ~name why =
  let fresh =
    Mutex.protect t.m (fun () ->
        let fresh = not (Hashtbl.mem t.seen ref_) in
        if fresh then Hashtbl.replace t.seen ref_ ();
        fresh)
  in
  if fresh then Log.info "cloud_files: %s is not shown here: %s" name why

let count t = Mutex.protect t.m (fun () -> Hashtbl.length t.seen)

let present t ~on_disk rows =
  let presented, others =
    Tsync_cloud_files_rules.Presentation.choose ~fold:Cf.upcase ~on_disk
      (List.filter_map
         (fun (row : Tsync_owner.Protocol.row) ->
           if row.kind = `Symlink then None else Some (row.name, row))
         rows)
  in
  List.iter
    (fun ((row : Tsync_owner.Protocol.row), why) ->
      note t ~ref_:row.ref_ ~name:row.name
        (match why with
          | `Unpresentable reason -> reason
          | `Case_group shown -> "its case group shows " ^ shown))
    others;
  List.iter
    (fun (row : Tsync_owner.Protocol.row) ->
      if row.kind = `Symlink then note t ~ref_:row.ref_ ~name:row.name "a link")
    rows;
  presented
