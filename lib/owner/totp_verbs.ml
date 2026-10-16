open Tsync_core
module Totp = Tsync_vault.Totp
module Fold = Tsync_vault.Fold
module Envelope = Tsync_vault.Envelope

let name = "totp"
let folder = Names.join Names.extension_root name

let check_uses (domain : Tsync_domain.Domain.t) =
  if not (List.mem name domain.domain.extensions) then
    Fail.invalid "%s does not use %s: add it to its extensions in the config"
      (Domain_name.to_string domain.name)
      name

type ctx = {
  engine : (module Tsync_sync.Engine.S);
  key : string;
  key_id : string;
}

let opened ctx (f : Fold.file) =
  match
    Envelope.open_ ~key:ctx.key ~key_id:ctx.key_id ~extension:name f.body
  with
    | Ok plaintext -> Result.to_option (Totp.of_string plaintext)
    | Error _ -> None

(* README §4.3, run before a verb reads: what a fold settles is never shown
   twice. *)
let settled ctx =
  let files = Vault.files ctx.engine folder in
  match
    Fold.grouped ~open_:(opened ctx) ~key:Totp.code_fields
      ~modified:(fun (r : Totp.t) -> r.modified)
      files
  with
    | [] -> files
    | actions ->
        Vault.apply ctx.engine folder actions;
        Vault.files ctx.engine folder

let context t ~domain ~engine ~lazy_tree =
  check_uses domain;
  let keyring, key = Vault.held t ~domain ~engine ~lazy_tree in
  if lazy_tree then (
    let (module E : Tsync_sync.Engine.S) = engine in
    if E.kind folder = `Dir then ignore (E.pull folder));
  { engine; key; key_id = keyring.Tsync_vault.Keyring.key_id }

let now () = int_of_float (Unix.time ())

let write ctx ~exclusive id record =
  let (module E : Tsync_sync.Engine.S) = ctx.engine in
  List.iter
    (fun dir -> E.mkdir dir ~exclusive:false)
    [Names.extension_root; folder];
  Vault.write_file ctx.engine ~exclusive (Names.join folder id)
    (Envelope.seal ~key:ctx.key ~key_id:ctx.key_id ~extension:name
       (Totp.to_string record))

let add t ~domain ~engine ~lazy_tree uri =
  let ctx = context t ~domain ~engine ~lazy_tree in
  match Totp.of_uri ~now:(now ()) uri with
    | Error e -> Fail.invalid "%s" e
    | Ok record ->
        let id = Ids.hex (Ids.urandom 16) in
        write ctx ~exclusive:true id record;
        id

(* §5: records that open, by id, and the ids that do not. *)
let same (a : Totp.t) (b : Totp.t) =
  a.issuer = b.issuer && a.account = b.account
  && Totp.code_fields a = Totp.code_fields b

let records ctx =
  List.fold_left
    (fun (ok, corrupt) (f : Fold.file) ->
      if not (Fold.is_record_id f.name) then (ok, corrupt)
      else (
        match opened ctx f with
          | Some r -> ((f.name, r) :: ok, corrupt)
          | None -> (ok, f.name :: corrupt)))
    ([], []) (settled ctx)
  |> fun (ok, corrupt) -> (List.rev ok, List.sort compare corrupt)

let contains ~sub s =
  let s = String.lowercase_ascii s and sub = String.lowercase_ascii sub in
  let n = String.length sub in
  let rec at i =
    i + n <= String.length s && (String.sub s i n = sub || at (i + 1))
  in
  at 0

let list t ~domain ~engine ~lazy_tree filter : Protocol.totp_listing =
  let ctx = context t ~domain ~engine ~lazy_tree in
  let ok, corrupt = records ctx in
  let unix_time = Int64.of_float (Unix.time ()) in
  let rows =
    List.filter_map
      (fun (id, (r : Totp.t)) ->
        match filter with
          | Some sub when not (contains ~sub r.issuer || contains ~sub r.account)
            ->
              None
          | _ ->
              Some
                {
                  Protocol.id;
                  issuer = r.issuer;
                  account = r.account;
                  code = Totp.code_at r ~unix_time;
                  seconds_left = Totp.seconds_left r ~unix_time;
                })
      ok
    |> List.sort (fun (a : Protocol.totp_row) b ->
        compare (a.issuer, a.account, a.id) (b.issuer, b.account, b.id))
  in
  { rows; corrupt }

let find ctx id =
  if not (Fold.is_record_id id) then Fail.invalid "%S is not a record id" id;
  let ok, corrupt = records ctx in
  match List.assoc_opt id ok with
    | Some r -> r
    | None when List.mem id corrupt ->
        Fail.corrupt "%s does not open under this vault's key" id
    | None -> Fail.absent "no record %s" id

let rename t ?issuer ?account ~domain ~engine ~lazy_tree ~id () =
  let ctx = context t ~domain ~engine ~lazy_tree in
  let r = find ctx id in
  let r =
    {
      r with
      issuer = Option.value ~default:r.issuer issuer;
      account = Option.value ~default:r.account account;
      modified = now ();
    }
  in
  if r.issuer = "" && r.account = "" then
    Fail.invalid "issuer and account cannot both be empty";
  write ctx ~exclusive:false id r

let remove t ~domain ~engine ~lazy_tree id =
  let ctx = context t ~domain ~engine ~lazy_tree in
  ignore (find ctx id);
  let (module E : Tsync_sync.Engine.S) = engine in
  E.delete (Names.join folder id)

(* §5.2: a [,] or [;] splits a line only before another otpauth URI. *)
let entries line =
  let n = String.length line in
  let starts_uri i =
    let rest = String.trim (String.sub line i (n - i)) in
    String.starts_with ~prefix:"otpauth://" (String.lowercase_ascii rest)
  in
  let rec go start i acc =
    if i = n then List.rev (String.sub line start (n - start) :: acc)
    else if (line.[i] = ',' || line.[i] = ';') && starts_uri (i + 1) then
      go (i + 1) (i + 1) (String.sub line start (i - start) :: acc)
    else go start (i + 1) acc
  in
  List.filter (fun e -> e <> "") (List.map String.trim (go 0 0 []))

(* §5.2: a refusal names the line, never its content. *)
let import t ~domain ~engine ~lazy_tree text : Protocol.totp_imported =
  let ctx = context t ~domain ~engine ~lazy_tree in
  let known = ref (List.map snd (fst (records ctx))) in
  let added = ref 0 and already = ref 0 and refused = ref [] in
  List.iteri
    (fun i line ->
      let several = List.length (entries line) > 1 in
      List.iteri
        (fun k uri ->
          match Totp.of_uri ~now:(now ()) uri with
            | Error reason ->
                let reason =
                  if several then Printf.sprintf "entry %d: %s" (k + 1) reason
                  else reason
                in
                refused := (i + 1, reason) :: !refused
            | Ok r when List.exists (same r) !known -> incr already
            | Ok r ->
                write ctx ~exclusive:true (Ids.hex (Ids.urandom 16)) r;
                known := r :: !known;
                incr added)
        (entries line))
    (String.split_on_char '\n' text);
  { added = !added; already = !already; refused = List.rev !refused }

(* README §4.2: the fold that waited for the key. *)
let fold t ~domain ~engine ~lazy_tree =
  if List.mem name domain.Tsync_domain.Domain.domain.extensions then
    ignore (records (context t ~domain ~engine ~lazy_tree))

let export t ~domain ~engine ~lazy_tree =
  let ctx = context t ~domain ~engine ~lazy_tree in
  fst (records ctx)
  |> List.sort (fun (a, (x : Totp.t)) (b, (y : Totp.t)) ->
      compare (x.issuer, x.account, a) (y.issuer, y.account, b))
  |> List.map (fun (_, r) -> Totp.to_uri r)
