(* The totp record, its codes and URIs (spec extensions/totp §2, §4, §5.1),
   and the folds of README §4.3 and vault §4.3. *)

open Tsync_vault

let p fmt = Printf.printf fmt

let record ?(issuer = "GitHub") ?(account = "me@example.com")
    ?(secret = "JBSWY3DPEHPK3PXP") ?(algorithm = `SHA1) ?(digits = 6)
    ?(period = 30) ?(modified = 1760500000) () : Totp.t =
  { issuer; account; secret; algorithm; digits; period; modified; unknown = [] }

let vectors () =
  p "== RFC 6238 appendix B, 8 digits\n";
  let seed s = Totp.base32_encode s in
  let sha1 = seed "12345678901234567890"
  and sha256 = seed "12345678901234567890123456789012"
  and sha512 =
    seed (String.concat "" (List.init 6 (fun _ -> "1234567890")) ^ "1234")
  in
  List.iter
    (fun (name, secret, algorithm, t) ->
      let r = record ~secret ~algorithm ~digits:8 () in
      p "%-7s %12Ld %s, %ds left\n" name t
        (Totp.code_at r ~unix_time:t)
        (Totp.seconds_left r ~unix_time:t))
    [
      ("SHA1", sha1, `SHA1, 59L);
      ("SHA1", sha1, `SHA1, 1111111109L);
      ("SHA1", sha1, `SHA1, 1234567890L);
      ("SHA1", sha1, `SHA1, 20000000000L);
      ("SHA256", sha256, `SHA256, 59L);
      ("SHA512", sha512, `SHA512, 59L);
    ]

let uris () =
  p "\n== otpauth URIs\n";
  let show uri =
    match Totp.of_uri ~now:7 uri with
      | Ok r ->
          p "%s\n  -> issuer %S account %S secret %s %s/%d/%d\n  -> %s\n" uri
            r.issuer r.account r.secret
            (match r.algorithm with
              | `SHA1 -> "SHA1"
              | `SHA256 -> "SHA256"
              | `SHA512 -> "SHA512")
            r.digits r.period (Totp.to_uri r)
      | Error e -> p "%s\n  refused: %s\n" uri e
  in
  List.iter show
    [
      "otpauth://totp/ACME%20Co:john@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co";
      "otpauth://totp/Label:me?secret=jbswy3dpehpk3pxp&issuer=Param";
      "otpauth://totp/Label:me?secret=JBSWY3DPEHPK3PXP%3D%3D%3D%3D";
      "otpauth://totp/me?secret=JBSWY3DPEHPK3PXP&algorithm=sha256&digits=8&period=60&foo=bar";
      "otpauth://hotp/me?secret=JBSWY3DPEHPK3PXP&counter=1";
      "otpauth://totp/me?secret=JBSWY3DPEHPK3PXP&digits=9";
      "otpauth://totp/me?secret=JBSWY3DPEHPK3PXP&algorithm=MD5";
      "otpauth://totp/me?secret=";
      "otpauth://totp/?secret=JBSWY3DPEHPK3PXP";
      "otpauth://totp/me?secret=JBSWY3DPEHPK3PX1";
      "OTPAUTH://TOTP/me?secret=JBSWY3DPEHPK3PXP";
      "otpauth://totp?secret=JBSWY3DPEHPK3PXP";
      "otpauth://steam?secret=JBSWY3DPEHPK3PXP";
      "otpauth://totp/me?secret=JBSWY3DPEHPK3PXP&digits=0x8";
      "otpauth://totp/A%3AB:me?secret=JBSWY3DPEHPK3PXP";
      "otpauth://totp/ACME%3Ame?secret=JBSWY3DPEHPK3PXP";
      "otpauth://totp/me?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY";
      "otpauth://totp/me?secret=GEZDGNBVGY3TQOJQGEZDGNBVGZ";
    ];
  p "a refusal holds no part of a URI's seed: %b\n"
    (List.for_all
       (fun uri ->
         match Totp.of_uri ~now:7 uri with
           | Error e ->
               not
                 (Tsync_core.Text.contains (String.uppercase_ascii e) "JBSWY3DP")
           | Ok _ -> false)
       [
         "otpauth://totp?secret=JBSWY3DPEHPK3PXP";
         "otpauth://hotp/me?secret=JBSWY3DPEHPK3PXP";
         "otpauth://totp/me?secret=JBSWY3DPEHPK3PXP&algorithm=JBSWY3DP";
       ]);
  p "\n== bare secrets\n";
  List.iter
    (fun (issuer, account, secret) ->
      p "%S %S %S -> %s\n" issuer account secret
        (match Totp.of_secret ~now:7 ~issuer ~account secret with
          | Ok r -> r.secret ^ " " ^ Totp.to_uri r
          | Error e -> "refused: " ^ e))
    [
      ("GitHub", "me", "jbsw y3dp ehpk 3pxp");
      ("GitHub", "", "JBSWY3DPEHPK3PXP====");
      ("", "", "JBSWY3DPEHPK3PXP");
      ("GitHub", "me", "not base32!");
      ("GitHub", "me", "");
    ];
  p "the bare secret and its URI give one record: %b\n"
    (Totp.of_secret ~now:7 ~issuer:"GitHub" ~account:"me" "jbsw y3dp ehpk 3pxp"
    = Totp.of_uri ~now:7
        "otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP&issuer=GitHub");
  List.iter
    (fun (issuer, account) ->
      p "export then add reproduces %S %S: %b\n" issuer account
        (let r = record ~issuer ~account ~digits:7 ~period:45 () in
         match Totp.of_uri ~now:r.modified (Totp.to_uri r) with
           | Ok back -> back = r
           | Error _ -> false))
    [("A & B", "x:y z"); ("A:B", "me"); ("", "a:b"); ("", "plain")]

let plaintexts () =
  p "\n== plaintexts\n";
  List.iter
    (fun s ->
      p "%-80s %s\n" s
        (match Totp.of_string s with
          | Ok r -> "ok, rewritten " ^ Totp.to_string r
          | Error e -> "CORRUPT: " ^ e))
    [
      Totp.to_string (record ());
      {|{"issuer":"G","account":"a","secret":"JBSWY3DPEHPK3PXP","algorithm":"SHA1","digits":6,"period":30,"modified":1,"later":[1]}|};
      {|{"issuer":"G","account":"a","secret":"jbswy3dpehpk3pxp","algorithm":"SHA1","digits":6,"period":30,"modified":1}|};
      {|{"issuer":"","account":"","secret":"JBSWY3DPEHPK3PXP","algorithm":"SHA1","digits":6,"period":30,"modified":1}|};
      {|{"issuer":"G","account":"a","secret":"JBSWY3DPEHPK3PXP","algorithm":"SHA1","digits":6,"period":30}|};
      {|[1]|};
    ]

(* A record's id is fixed; files are named as the merge names copies. *)
let id = String.make 32 'a'

let copy n =
  Printf.sprintf "%s (conflicted copy%s from laptop)" id
    (if n = 1 then "" else " " ^ string_of_int n)

let show_fold label files =
  let open_ (f : Fold.file) =
    if String.starts_with ~prefix:"bad" f.body then None
    else Result.to_option (Totp.of_string f.body)
  in
  p "%s\n" label;
  match
    Fold.grouped ~open_ ~key:Totp.code_fields
      ~modified:(fun (r : Totp.t) -> r.modified)
      files
  with
    | [] -> p "  nothing to do\n"
    | actions ->
        List.iter
          (function
            | Fold.Move { src; dst } -> p "  move %s -> %s\n" src dst
            | Remove n -> p "  remove %s\n" n
            | Write { name; _ } -> p "  write %s\n" name)
          actions

let folds () =
  p "\n== grouped fold\n";
  let body r = Totp.to_string r in
  let f name r : Fold.file = { name; body = body r } in
  show_fold "one record, no copy" [f id (record ())];
  show_fold "two renames: the newer labels win, at the id"
    [
      f id (record ~issuer:"Old" ~modified:10 ());
      f (copy 1) (record ~issuer:"New" ~modified:20 ());
    ];
  show_fold "the newer one is already at the id"
    [
      f id (record ~issuer:"New" ~modified:20 ());
      f (copy 1) (record ~issuer:"Old" ~modified:10 ());
    ];
  show_fold "a tie on modified: the bytewise greatest"
    [f id (record ~issuer:"A" ()); f (copy 1) (record ~issuer:"B" ())];
  show_fold "another seed survives at its digest id"
    [f id (record ()); f (copy 1) (record ~secret:"GEZDGNBVGY3TQOJQ" ())];
  show_fold "no file at the id: the newest group takes it"
    [
      f (copy 1) (record ~modified:5 ());
      f (copy 2) (record ~secret:"GEZDGNBVGY3TQOJQ" ~modified:9 ());
    ];
  show_fold "the file at the id does not open: kept, every group to its digest"
    [
      { name = id; body = "bad" };
      f (copy 1) (record ());
      f (copy 2) (record ~modified:9 ());
    ];
  show_fold "a copy that does not open is left"
    [f id (record ()); { name = copy 1; body = "bad" }];
  show_fold "a leaf that is no record id is ignored"
    [
      { name = "notes.txt"; body = "x" };
      { name = "notes (conflicted copy from b).txt"; body = "y" };
    ];
  p "folding the result again does nothing: %b\n"
    (let files =
       [
         f id (record ~issuer:"Old" ~modified:10 ());
         f (copy 1) (record ~issuer:"New" ~modified:20 ());
       ]
     in
     let actions =
       Fold.grouped
         ~open_:(fun (x : Fold.file) ->
           Result.to_option (Totp.of_string x.body))
         ~key:Totp.code_fields
         ~modified:(fun (r : Totp.t) -> r.modified)
         files
     in
     let after =
       List.fold_left
         (fun files -> function
           | Fold.Move { src; dst } ->
               let moved =
                 List.find (fun (x : Fold.file) -> x.name = src) files
               in
               { moved with name = dst }
               :: List.filter
                    (fun (x : Fold.file) -> x.name <> src && x.name <> dst)
                    files
           | Remove n -> List.filter (fun (x : Fold.file) -> x.name <> n) files
           | Write w -> { Fold.name = w.name; body = w.body } :: files)
         files actions
     in
     Fold.grouped
       ~open_:(fun (x : Fold.file) -> Result.to_option (Totp.of_string x.body))
       ~key:Totp.code_fields
       ~modified:(fun (r : Totp.t) -> r.modified)
       after
     = [])

let keyrings () =
  p "\n== keyring fold\n";
  let k = { Keyring.key_id = "0123456789abcdef"; slots = []; extra = [] } in
  let slot id =
    Keyring.Unknown
      { id; json = `Assoc [("id", `String id); ("kind", `String "later")] }
  in
  let ring slots = Keyring.to_string { k with slots } in
  let show label files =
    let actions, left = Fold.keyring ~name:"keyring" files in
    p "%s\n" label;
    List.iter
      (function
        | Fold.Write { name; body } -> p "  write %s %s\n" name body
        | Remove n -> p "  remove %s\n" n
        | Move _ -> p "  move?\n")
      actions;
    List.iter (p "  left %s\n") left;
    if actions = [] && left = [] then p "  nothing to do\n"
  in
  let copy = "keyring (conflicted copy from laptop)" in
  show "each added a slot: the union"
    [
      { name = "keyring"; body = ring [slot "1111111111111111"] };
      { name = copy; body = ring [slot "2222222222222222"] };
    ];
  show "the copy adds nothing: removed"
    [
      { name = "keyring"; body = ring [slot "1111111111111111"] };
      { name = copy; body = ring [slot "1111111111111111"] };
    ];
  show "another key id: left and reported"
    [
      { name = "keyring"; body = ring [slot "1111111111111111"] };
      {
        name = copy;
        body =
          Keyring.to_string
            {
              key_id = "fedcba9876543210";
              slots = [slot "3333333333333333"];
              extra = [];
            };
      };
    ];
  show "no copy" [{ name = "keyring"; body = ring [slot "1111111111111111"] }]

let () =
  vectors ();
  uris ();
  plaintexts ();
  folds ();
  keyrings ()

let () =
  p "\n== the client a copy came from\n";
  let id = String.make 32 'a' in
  List.iter
    (fun name ->
      p "%-60s %s\n" name
        (Option.value ~default:"-" (Tsync_vault.Fold.copied_from name)))
    [
      id;
      id ^ " (conflicted copy from laptop)";
      id ^ " (conflicted copy 2 from the phone)";
      id ^ " (something else)";
    ]
