(* Share links (spec 05 §4.11, security §6.1–6.2, 02 §2.14): the member that
   serves links, presence on it, manifests by kind, tokens, revoke and the
   share cache. *)

open Tsync_core
open Tsync_store
open Tsync_gc

let p fmt = Printf.printf fmt
let d = Domain_name.v "d"

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-share-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let main = Local.create ~name:"main" (Filename.concat root "main")
  and inner = Local.create ~name:"copy" (Filename.concat root "copy") in
  let copy =
    {
      inner with
      capabilities =
        (fun _ ->
          { Store.no_caps with share_url = Some "https://s.example/d/" });
    }
  in
  let cs = Chunking.chunk_size_min in
  let folder = Folder_id.v "0000000000a1-1"
  and empty = Folder_id.v "0000000000a2-1" in
  let objects =
    [
      (Key.chunk d (Chunk_key.of_body "x"), "x");
      ( Key.child d Folder_id.root "a.txt",
        (Manifest.make ~name:"a.txt" ~size:cs ~mtime:0. ~chunk_size:cs
           [Chunk_key.of_body "x"])
          .body );
      ( Key.child d Folder_id.root "docs",
        Folder.marker_body { name = "docs"; id = folder } );
      ( Key.anchor d folder,
        Folder.anchor_body { parent = Folder_id.root; aname = "docs" } );
      ( Key.child d folder "b.txt",
        (Manifest.make ~name:"b.txt" ~size:cs ~mtime:0. ~chunk_size:cs
           [Chunk_key.of_body "x"])
          .body );
      ( Key.child d Folder_id.root "p.jpg",
        (Manifest.make ~name:"p.jpg" ~size:cs ~mtime:0. ~chunk_size:cs
           [Chunk_key.of_body "x"])
          .body );
      ( Key.child d Folder_id.root "empty",
        Folder.marker_body { name = "empty"; id = empty } );
      ( Key.anchor d empty,
        Folder.anchor_body { parent = Folder_id.root; aname = "empty" } );
    ]
  in
  let put (s : Store.t) =
    List.iter (fun (k, b) -> s.put k (Bigstring.of_string b))
  in
  let context members =
    let composite =
      Composite.create ~domain:d
        ~data_dir:(Filename.concat root "data")
        ~owner:true ~poke:ignore
        ~knowledge:
          {
            Composite.is_index = (fun _ -> false);
            is_journal = (fun _ -> false);
          }
        members
    in
    (module struct
      let domain = d
      let store = Composite.store composite
      let composite = composite
      let versioning = true
      let chunk_size_config = None
      let max_downloads = 1
      let max_chunk_buffers = 4
    end : Tsync_remote.Context.S)
  in
  Rt.run_sync (fun () ->
      put main objects;
      let module S =
        Share.Make
          ((val context
                  [
                    { name = "main"; role = Main; store = main };
                    { name = "copy"; role = Replica; store = copy };
                  ])) in
      let token_of url =
        String.sub url
          (String.rindex url '/' + 1)
          (String.length url - String.rindex url '/' - 1)
      in
      let manifest url =
        match copy.get_opt (Option.get (Key.share (token_of url))) with
          | Some b ->
              Text.replace_all ~sub:(token_of url) ~by:"<token>"
                (Bigstring.to_string b)
          | None -> "(none)"
      in
      let now = Unix.gettimeofday () in
      let create label ?expires ?token rel =
        match S.create ?expires ?token rel with
          | c ->
              let shown =
                Text.replace_all
                  ~sub:(Printf.sprintf "%.0f" c.expires)
                  ~by:"<exp>" (manifest c.url)
              in
              p "%s: %s, in %.0f days\n  %s\n" label
                (Text.replace_all ~sub:(token_of c.url) ~by:"<token>" c.url)
                ((c.expires -. now) /. 86400.)
                shown;
              Some c
          | exception Fail.E f ->
              p "%s: refused (%s): %s\n" label (Fail.kind_name f.kind) f.reason;
              None
      in
      p "== the object must be on the member serving links\n";
      ignore (create "a.txt" "a.txt");
      put copy objects;
      p "\n== by kind\n";
      let file = create "a.txt" "a.txt" in
      ignore (create "docs" ~expires:3600. "docs");
      ignore (create "the domain" ~expires:(30. *. 86400.) "");
      ignore (create "empty" "empty");
      ignore (create "nowhere" "nowhere");
      p "\n== chosen tokens\n";
      let tok = String.make 32 'a' in
      ignore (create "a token" ~token:tok "a.txt");
      ignore (create "the same token" ~token:tok "docs");
      ignore (create "a short token" ~token:"abc" "a.txt");
      p "\n== preview images\n";
      let preview label s =
        p "%s: %s\n" label
          (match S.preview s with
            | `Made -> "made"
            | `Not_made why -> "not made: " ^ why
            | exception Fail.E f -> Fail.kind_name f.kind ^ ": " ^ f.reason)
      in
      let photo = Option.get (create "p.jpg" "p.jpg") in
      preview "without a thumbnailer" photo.url;
      let asked = ref "" in
      (* A 800x450 baseline frame header. *)
      let image =
        "\xFF\xD8\xFF\xC0\x00\x0B\x08\x01\xC2\x03\x20\x01\x01\x11\x00\xFF\xD9"
      in
      Atomic.set Share_preview.thumbnailer
        (Some
           (fun ~kind:_ ~deadline:_ url ->
             asked := url;
             Some (Bigstring.of_string image)));
      preview "an image, by link" photo.url;
      p "read through %s, stored beside the manifest: %b\n"
        (Text.replace_all ~sub:(token_of photo.url) ~by:"<token>" !asked)
        (copy.get_opt (Option.get (Key.share_preview (token_of photo.url)))
        = Some (Bigstring.of_string image));
      preview "a text file" (Option.get file).url;
      preview "a folder" (Option.get (create "docs again" "docs")).url;
      preview "an unknown token" (String.make 32 'c');
      Atomic.set Share_preview.thumbnailer
        (Some (fun ~kind:_ ~deadline:_ _ -> Some (Bigstring.of_string "no")));
      preview "an invalid image made" (token_of photo.url);
      let revoked = S.revoke photo.url in
      p "revoke an image share: %b, preview image gone: %b\n" revoked
        (copy.get_opt (Option.get (Key.share_preview (token_of photo.url)))
        = None);
      let racing = Option.get (create "p.jpg, revoked mid-decode" "p.jpg") in
      Atomic.set Share_preview.thumbnailer
        (Some
           (fun ~kind:_ ~deadline:_ _ ->
             ignore (S.revoke racing.url);
             Some (Bigstring.of_string image)));
      preview "revoked while the image is made" racing.url;
      p "no image left behind: %b\n"
        (copy.get_opt (Option.get (Key.share_preview (token_of racing.url)))
        = None);
      p "\n== revoke\n";
      let file = Option.get file in
      copy.put
        (Key.v ("tsync/shares/cache/" ^ token_of file.url ^ ".data"))
        (Bigstring.of_string "zip");
      p "revoke by link: %b\n" (S.revoke file.url);
      p "manifest gone: %b, cached download gone: %b\n"
        (copy.get_opt (Option.get (Key.share (token_of file.url))) = None)
        (copy.get_opt
           (Key.v ("tsync/shares/cache/" ^ token_of file.url ^ ".data"))
        = None);
      p "again: %b\n" (S.revoke file.url);
      let other = String.make 32 'b' in
      copy.put
        (Option.get (Key.share other))
        (Bigstring.of_string
           {|{"v":1,"expires":9999999999,"domain":"e","type":"dir","folderId":".tsync-root","filename":"e.zip"}|});
      p "another domain's share: %b, still there: %b\n" (S.revoke other)
        (copy.get_opt (Option.get (Key.share other)) <> None);
      p "\n== the share cache\n";
      copy.put
        (Key.v "tsync/shares/cache/0123-4567.data")
        (Bigstring.of_string "12345");
      copy.put (Key.v "tsync/shares/stray.data") (Bigstring.of_string "123");
      let n, bytes = S.clear_cache () in
      p "deleted %d objects (%d bytes); links kept: %b\n" n bytes
        (copy.get_opt (Option.get (Key.share tok)) <> None));
  Rt.run_sync (fun () ->
      let module S =
        Share.Make ((val context [{ name = "main"; role = Main; store = main }])) in
      p "\n== no member serves links\n";
      match S.create "a.txt" with
        | _ -> p "created\n"
        | exception Fail.E f -> p "refused: %s\n" f.reason);
  Fs.rm_rf root
