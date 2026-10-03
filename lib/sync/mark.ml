open Tsync_core

let path ~data_dir domain =
  Filename.concat data_dir ("last-sync-" ^ Domain_name.to_string domain)

let read ~data_dir domain =
  match Fs.read_file_opt (path ~data_dir domain) with
    | None -> None
    | Some s -> (
        match Entry_key.parse (String.trim s) with
          | Some k -> Some k
          | None ->
              (* Set aside, so the rebuild it causes writes a mark that holds. *)
              let p = path ~data_dir domain in
              let aside =
                Filename.concat (Filename.dirname p)
                  (".tsync-bad-" ^ Filename.basename p)
              in
              Log.warn
                "%s does not hold an entry key; set aside as %s and treated as \
                 no mark"
                p aside;
              (try Fs.rename p aside with _ -> ());
              None)

let write ~data_dir domain k =
  Fs.durable_replace (path ~data_dir domain) (Entry_key.to_string k ^ "\n")
