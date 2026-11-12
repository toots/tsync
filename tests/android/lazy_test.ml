(* android §9, Freshness and Without the store, over Lazy_harness. *)

open Tsync_core
open Tsync_android
open Lazy_harness

let () =
  Lazy_harness.setup ();

  p "== before boot";
  p "  %-34s %s" "request"
    (Android_host.request "docs" {|{"action":"stat","ref":"root"}|});
  p "  %-34s %d" "open" (Android_host.open_ "docs" "root");
  p "  %-34s %S" "check_config" (Android_host.check_config "");
  p "  %-34s %S" "check_config of another domain"
    (Android_host.check_config "nope");

  p "== cleartext only to loopback";
  List.iter
    (fun host -> p "  %-34s %b" host (Tsync_http.Transport.is_loopback host))
    [
      "localhost";
      "127.0.0.1";
      "127.9.9.9";
      "[::1]";
      "127.0.0.1.example.org";
      "127.example.org";
      "192.168.1.4";
      "127.0.0.256";
    ];

  peer_writes "a.txt" "from the peer";
  peer_does (fun (module E) -> E.mkdir "sub" ~exclusive:true);
  peer_writes "sub/deep.txt" "deep";

  p "== boot";
  p "  %-34s %S" "boot"
    (Android_host.boot
       ~pull_params:
         {
           pull_freshness = fresh_window;
           view_max_age = 3600.;
           pull_patience = 0.5;
           refresh_patience = 20.;
           pull_page = 256;
         }
       "");
  p "  %-34s %S" "boot again" (Android_host.boot "");
  p "  %-34s %s" "not JSON" (Android_host.request "docs" "{nope");

  p "== freshness";
  let l = list "root, mirror empty" "root" in
  let sub = ref_of l "sub" and a = ref_of l "a.txt" in
  ignore (list "root again, within freshness" "root");
  ignore (list ~extra:[s "pull" "now"] "root, pull now" "root");
  ignore (list ~extra:[s "pull" "never"] "sub, pull never" sub);
  ignore (list "sub" sub);
  show_notices "notices";
  let paged =
    list
      ~extra:[("limit", `Int 1); s "pull" "now"]
      "root, first page of 1" "root"
  in
  wait_stale ();
  ignore
    (list
       ~extra:[("limit", `Int 1); s "after" (text paged "next")]
       "root, next page, later" "root");

  p "== a peer's changes";
  p "  %-34s %s" "open a.txt" (read_all a);
  let kept = Android_host.open_ "docs" a in
  peer_writes "a.txt" "replaced by the peer";
  peer_writes "b.txt" "new";
  p "  %-34s %s" "open a.txt after the peer replaced it" (read_all a);
  let buffer = Bigstring.create 64 in
  let n = Android_host.read kept ~off:0 buffer in
  p "  %-34s %S of %d" "the handle opened before"
    (Bigstring.to_string ~off:0 ~len:(max n 0) buffer)
    (Android_host.size kept);
  ignore (Android_host.close kept);
  p "  %-34s %d" "read after close" (Android_host.read kept ~off:0 buffer);
  wait_stale ();
  let l = list "root" "root" in
  let b = ref_of l "b.txt" in
  show_notices "notices";
  peer_does (fun (module E) -> E.delete "b.txt");
  p "  %-34s %s" "open b.txt after the peer deleted it" (read_all b);
  wait_stale ();
  ignore (list "root" "root");
  show_notices "notices";

  p "== owed work survives a pull";
  p "  %-34s %s" "pause" (outcome (action "pause" []));
  p "  %-34s %s" "create mine.txt"
    (outcome (action "create" [s "parentRef" "root"; s "name" "mine.txt"]));
  p "  %-34s %s" "create mine.txt, exclusive"
    (outcome
       (action "create"
          [s "parentRef" "root"; s "name" "mine.txt"; ("exclusive", `Bool true)]));
  p "  %-34s %s" "delete a.txt" (outcome (action "delete" [s "ref" a]));
  ignore (list ~extra:[s "pull" "now"] "root, pull now" "root");
  p "  %-34s %s" "resume" (outcome (action "pause" [s "arg" "off"]));
  until_uploaded "mine.txt";
  show_notices "notices";

  p "== refused on a pulled tree";
  List.iter
    (fun name -> p "  %-34s %s" name (outcome (action name [s "arg" ""])))
    ["full_resync"; "sync"; "subscribe"];

  p "== the store pends";
  peer_writes "c.txt" "while the phone was away";
  wait_stale ();
  Atomic.set mode `Hung;
  ignore (list "root, listed before" "root");
  p "  %-34s %s" "mkdir offline"
    (outcome (action "mkdir" [s "parentRef" "root"; s "name" "offline"]));
  p "== the store is down";
  Atomic.set mode `Down;
  wait_stale ();
  p "  %-34s %s" "write note.txt"
    (let j =
       action "write"
         [
           s "parentRef" "root";
           s "name" "note.txt";
           s "staging" (staged "s1" "written offline");
           ("await", `Bool true);
         ]
     in
     outcome j
     ^
       match field j "item" with
       | Some i when field i "isUploaded" = Some (`Bool false) ->
           ", not uploaded"
       | _ -> ", uploaded");
  let l = list ~extra:[s "pull" "never"] "root, pull never" "root" in
  let note = ref_of l "note.txt" in
  p "  %-34s %s" "rename note.txt"
    (outcome
       (action "rename" [s "ref" note; s "parentRef" "root"; s "name" "n2.txt"]));
  p "  %-34s %s" "open n2.txt" (read_all note);
  p "  %-34s %s" "status answers"
    (if field (action "status" []) "ok" = Some (`Bool true) then "ok" else "no");

  ignore (list "root, listed before" "root");
  let offline =
    ref_of (list ~extra:[s "pull" "never"] "root, pull never" "root") "offline"
  in
  ignore (list "a folder never listed" offline);
  outdate [];
  ignore (list "root, its view too old" "root");

  p "== the store returns";
  Atomic.set mode `Up;
  ignore (list "root" "root");
  until_uploaded "n2.txt";
  show_notices "notices";
  let l = list ~extra:[s "pull" "now"] "root, uploads published" "root" in
  p "  %-34s [%s]" "the peer sees"
    (String.concat ", " (until_peer_sees "offline"));

  p "== a subfolder moves into a folder never pulled";
  peer_does (fun (module E) ->
      E.mkdir "sub/inner" ~exclusive:true;
      E.mkdir "archive" ~exclusive:true;
      E.mkdir "archive/old" ~exclusive:true);
  ignore (list ~extra:[s "pull" "now"] "sub, holding inner" sub);
  peer_does (fun (module E) ->
      E.rename ~src:"sub/inner" ~dst:"archive/old/inner" ~exclusive:true;
      E.rename ~src:"archive/old/inner" ~dst:"archive/old/again" ~exclusive:true);
  ignore (list ~extra:[s "pull" "now"] "sub, inner gone" sub);
  ignore (list ~extra:[s "pull" "now"] "root" "root");
  peer_does (fun (module E) ->
      p "  %-34s [%s]" "the peer's root"
        (String.concat ", "
           (List.sort compare
              (List.map (fun (e : E.entry) -> e.name) (E.list_children ""))));
      p "  %-34s [%s]" "the peer's archive/old"
        (String.concat ", "
           (List.map
              (fun (e : E.entry) -> e.name)
              (E.list_children "archive/old"))));

  p "== a pin holds the views that lead to it";
  let deep = ref_of (list "sub" sub) "deep.txt" in
  p "  %-34s %s" "restore sub/deep.txt"
    (Yojson.Safe.to_string
       (action "restore" [s "ref" deep; ("keep", `Int 600)]));
  outdate [];
  outdate ["sub"];
  Atomic.set mode `Down;
  wait_stale ();
  ignore (list "root, view old but held" "root");
  ignore (list "sub, view old but held" sub);
  p "  %-34s %s" "open the pinned file" (read_all deep);
  p "  %-34s %s" "restore root"
    (Yojson.Safe.to_string (action "restore" [s "ref" "root"]));
  Atomic.set mode `Up;
  ignore l;
  p "  %-34s %s" "evict root"
    (Yojson.Safe.to_string (action "evict" [s "ref" "root"]));
  p "  %-34s %s" "restore root"
    (Yojson.Safe.to_string (action "restore" [s "ref" "root"]));

  p "== a folder removed over views that grew old";
  peer_writes "archive/old/again/kept.txt" "kept";
  (* The restore above pulled these folders: their views are let grow old. *)
  wait_stale ();
  let l = list ~extra:[s "pull" "now"] "root" "root" in
  p "  %-34s %s" "rmdir archive"
    (Yojson.Safe.to_string (action "rmdir" [s "ref" (ref_of l "archive")]));
  let peer_root () =
    let names = ref [] in
    peer_does (fun (module E) ->
        names := List.map (fun (e : E.entry) -> e.name) (E.list_children ""));
    List.sort compare !names
  in
  let deadline = Unix.gettimeofday () +. 20. in
  while List.mem "archive" (peer_root ()) && Unix.gettimeofday () < deadline do
    Thread.delay 0.05
  done;
  (* A peer that still held something under the folder would restore it
     (conflict-resolution R1) and publish that. *)
  ignore (peer_root ());
  p "  %-34s [%s]" "the peer's root, settled"
    (String.concat ", " (peer_root ()));
  ignore (list ~extra:[s "pull" "now"] "root" "root");

  p "== a write into a folder never pulled";
  peer_does (fun (module E) -> E.mkdir "fresh" ~exclusive:true);
  let fresh = ref_of (list ~extra:[s "pull" "now"] "root" "root") "fresh" in
  let write_fresh label =
    p "  %-34s %s" label
      (outcome
         (action "write"
            [
              s "parentRef" fresh;
              s "name" "f.txt";
              s "staging" (staged "s10" "f");
            ]))
  in
  Atomic.set mode `Down;
  write_fresh "write, the store down";
  Atomic.set mode `Up;
  write_fresh "write, the store back";

  p "== a folder made offline where a peer made one";
  ignore (list ~extra:[s "pull" "now"] "root" "root");
  peer_does (fun (module E) -> E.mkdir "camera" ~exclusive:true);
  peer_writes "camera/theirs.jpg" "theirs";
  Atomic.set mode `Down;
  wait_stale ();
  let made = action "mkdir" [s "parentRef" "root"; s "name" "camera"] in
  let mine = text (Option.get (field made "item")) "ref" in
  p "  %-34s %s" "mkdir camera" (outcome made);
  p "  %-34s %s" "write camera/ours.jpg"
    (outcome
       (action "write"
          [
            s "parentRef" mine;
            s "name" "ours.jpg";
            s "staging" (staged "s9" "ours");
          ]));
  Atomic.set mode `Up;
  let l = list ~extra:[s "pull" "now"] "root" "root" in
  ignore (list ~extra:[s "pull" "now"] "camera" (ref_of l "camera"));
  p "  %-34s %s" "the folder made offline"
    (text (action "list_dir" [s "ref" mine]) "code");
  let camera = ref_of l "camera" in
  let deadline = Unix.gettimeofday () +. 20. in
  while
    field
      (action "stat" [s "parentRef" camera; s "name" "ours.jpg"])
      "isUploaded"
    <> Some (`Bool true)
    && Unix.gettimeofday () < deadline
  do
    Thread.delay 0.05
  done;
  ignore (list ~extra:[s "pull" "now"] "camera, upload done" camera);
  let peer_camera () =
    let names = ref [] in
    peer_does (fun (module E) ->
        names :=
          List.map (fun (e : E.entry) -> e.name) (E.list_children "camera"));
    List.sort compare !names
  in
  let deadline = Unix.gettimeofday () +. 20. in
  while
    (not (List.mem "ours.jpg" (peer_camera ())))
    && Unix.gettimeofday () < deadline
  do
    Thread.delay 0.05
  done;
  p "  %-34s [%s]" "the peer's camera" (String.concat ", " (peer_camera ()));
  p "  %-34s [%s]" "the peer's root"
    (String.concat ", "
       (List.filter
          (fun n -> String.length n >= 6 && String.sub n 0 6 = "camera")
          (until_peer_sees "camera")));

  p "== a write into a folder made here and published";
  let made = action "mkdir" [s "parentRef" "root"; s "name" "made"] in
  let made = text (Option.get (field made "item")) "ref" in
  ignore (until_peer_sees "made");
  Atomic.set mode `Down;
  p "  %-34s %s" "write, the store down"
    (outcome
       (action "write"
          [s "parentRef" made; s "name" "m.txt"; s "staging" (staged "s11" "m")]));
  Atomic.set mode `Up;
  p "== the vault, then the store down (extensions README §4.1)";
  let vault label =
    let r = action "vault_status" [] in
    p "  %-34s %s%s%s" label
      (Option.value ~default:(outcome r)
         (Option.map (fun _ -> text r "vault") (field r "vault")))
      (if field r "outdated" = Some (`Bool true) then " outdated" else "")
      (if field r "pulledAt" <> None then " pulledAt" else "")
  in
  let codes label =
    let r = action "totp_list" [] in
    match field r "records" with
      | Some (`List rows) ->
          p "  %-34s %d record(s)%s" label (List.length rows)
            (if field r "outdated" = Some (`Bool true) then ", outdated" else "")
      | _ -> p "  %-34s %s" label (outcome r)
  in
  p "  %-34s %s" "init"
    (outcome
       (action "vault_init" [s "passphrase" "correct horse battery staple"]));
  p "  %-34s %s" "add"
    (outcome
       (action "totp_add"
          [s "uri" "otpauth://totp/Online:me?secret=JBSWY3DPEHPK3PXP"]));
  vault "status";
  codes "codes";
  wait_stale ();
  Atomic.set mode `Down;
  vault "status, the store down";
  codes "codes, the store down";
  p "  %-34s %s" "add, the store down"
    (outcome
       (action "totp_add"
          [s "uri" "otpauth://totp/Offline:me?secret=JBSWY3DPEHPK3PXP"]));
  codes "codes after it";
  p "  %-34s %s" "init, the store down"
    (outcome
       (action "vault_init" [s "passphrase" "correct horse battery staple"]));
  p "  %-34s %s" "passphrase, the store down"
    (outcome
       (action "vault_passphrase" [s "passphrase" "another passphrase, longer"]));
  Atomic.set mode `Up;
  wait_stale ();
  vault "status, the store back";
  codes "codes, the store back";
  p "== a read with pull background, the store silent (android §3.2 rule 1)";
  p "  %-34s %s" "add a login"
    (outcome
       (action "passwords_add"
          [
            s "title" "GitHub";
            ("urls", `List [`String "https://github.com"]);
            s "username" "me";
            s "password" "hunter2";
          ]));
  let timed label extra =
    let started = Unix.gettimeofday () in
    let r = action "passwords_list" ([s "site" "https://github.com"] @ extra) in
    let took = Unix.gettimeofday () -. started in
    p "  %-34s %s in %s" label
      (match field r "records" with
        | Some (`List rows) ->
            Printf.sprintf "%d row(s)%s" (List.length rows)
              (if field r "outdated" = Some (`Bool true) then ", outdated"
               else "")
        | _ -> outcome r)
      (if took < 1. then "under a second" else "a second or more")
  in
  timed "list, the store up" [];
  wait_stale ();
  Atomic.set mode `Hung;
  timed "list, pull auto" [];
  wait_stale ();
  timed "list, pull background" [s "pull" "background"];
  (* android-app §5.1: the vault screens' first read answers from the last
     view at once. *)
  let read label verb extra =
    wait_stale ();
    let started = Unix.gettimeofday () in
    let r = action verb extra in
    let took = Unix.gettimeofday () -. started in
    p "  %-34s %s%s in %s" label (outcome r)
      (if field r "outdated" = Some (`Bool true) then ", outdated" else "")
      (if took < 1. then "under a second" else "a second or more")
  in
  read "vault status, pull auto" "vault_status" [];
  read "vault status, pull background" "vault_status" [s "pull" "background"];
  read "codes, pull auto" "totp_list" [];
  read "codes, pull background" "totp_list" [s "pull" "background"];
  Atomic.set mode `Up;
  p "== a record whose body the phone lacks (extensions README §4.1)";
  (* The peer has no K: it writes a body that differs from every one the
     phone holds, one byte of the login's changed, which does not open. *)
  let login_id =
    match field (action "passwords_list" []) "records" with
      | Some (`List (`Assoc r :: _)) -> (
          match List.assoc_opt "id" r with Some (`String id) -> id | _ -> "")
      | _ -> ""
  in
  let copy = String.make 32 'c' in
  (* The phone's push of the login reaches the peer on its own time. *)
  let src = ".tsync-ext/passwords/" ^ login_id in
  let deadline = Unix.gettimeofday () +. 20. in
  let rec until_peer_has () =
    let has = ref false in
    peer_does (fun (module E) -> has := E.kind src = `File);
    if (not !has) && Unix.gettimeofday () < deadline then (
      Thread.delay 0.1;
      until_peer_has ())
  in
  until_peer_has ();
  peer_does (fun (module E) ->
      let h = E.open_read src in
      let body = E.read h ~off:0 ~len:(E.stat src).size in
      E.close_read h;
      let dst = ".tsync-ext/passwords/" ^ copy in
      E.create dst ~exclusive:true;
      let body = Bigstring.to_string body in
      let flipped =
        String.mapi
          (fun i c ->
            if i = String.length body - 1 then Char.chr (Char.code c lxor 1)
            else c)
          body
      in
      E.write dst ~off:0 (Bigstring.of_string flipped);
      E.close dst);
  let rows extra =
    let started = Unix.gettimeofday () in
    let r = action "passwords_list" extra in
    let took = Unix.gettimeofday () -. started in
    ( (match field r "corrupt" with
        | Some (`List rows) -> List.length rows
        | _ -> -1),
      field r "outdated" = Some (`Bool true),
      took )
  in
  (* Only bodies are withheld: the phone lists the copy and cannot read it. *)
  Atomic.set mode `Bodies_hung;
  wait_stale ();
  ignore (rows [s "pull" "background"]);
  Thread.delay 0.5;
  let n, outdated, took = rows [s "pull" "background"] in
  p "  %-34s %d not opening%s in %s" "list, bodies withheld" n
    (if outdated then ", outdated" else "")
    (if took < 1. then "under a second" else "a second or more");
  Atomic.set mode `Up;
  let deadline = Unix.gettimeofday () +. 20. in
  let rec fetched () =
    let n, _, _ = rows [s "pull" "background"] in
    if n >= 1 || Unix.gettimeofday () > deadline then n
    else (
      Thread.delay 0.1;
      fetched ())
  in
  p "  %-34s %d not opening" "list once it is fetched" (fetched ());
  p "== status";
  p "  %-34s %b" "names the frontend"
    (let st = Android_host.status "docs" in
     let rec has i =
       i + 16 <= String.length st
       && (String.sub st i 16 = "Frontend android" || has (i + 1))
     in
     has 0);
  Test_support.finish root;
  exit 0
