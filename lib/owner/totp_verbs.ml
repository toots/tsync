open Tsync_core
module Totp = Tsync_vault.Totp
module Fold = Tsync_vault.Fold
module Envelope = Tsync_vault.Envelope

include Extension_records.Make (struct
  type t = Totp.t

  let name = "totp"
  let of_string = Totp.of_string
  let to_string = Totp.to_string
  let key_fields = Totp.code_fields
  let modified (r : Totp.t) = r.modified

  (* §3: on the issuer, or the account when the issuer is empty. *)
  let relabel ~suffix (r : Totp.t) =
    if String.ends_with ~suffix r.issuer || String.ends_with ~suffix r.account
    then None
    else if r.issuer <> "" then Some { r with issuer = r.issuer ^ suffix }
    else Some { r with account = r.account ^ suffix }
end)

let add ~domain ~engine ~lazy_tree t source =
  let ctx = context ~writing:true ~domain ~engine ~lazy_tree t in
  match
    match source with
      | `Uri uri -> Totp.of_uri ~now:(now ()) uri
      | `Secret (s : Protocol.totp_secret) ->
          Totp.of_secret ~now:(now ()) ~issuer:s.issuer ~account:s.account
            s.secret
  with
    | Error e -> Fail.invalid "%s" e
    | Ok record ->
        let id = Ids.token () in
        write ctx ~exclusive:true id record;
        id

let same (a : Totp.t) (b : Totp.t) =
  a.issuer = b.issuer && a.account = b.account
  && Totp.code_fields a = Totp.code_fields b

let contains ~sub s =
  Text.contains (String.lowercase_ascii s) (String.lowercase_ascii sub)

let list ~domain ~engine ~lazy_tree t filter : Protocol.totp_listing =
  let ctx = context ~domain ~engine ~lazy_tree t in
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
  let view = Atomic.get t.Vault.view in
  { rows; corrupt; outdated = view.outdated; pulled_at = view.pulled_at }

let code ?pull ~domain ~engine ~lazy_tree t id : Protocol.totp_code =
  let ctx = context ?pull ~domain ~engine ~lazy_tree t in
  let r = find ctx id in
  let unix_time = Int64.of_float (Unix.time ()) in
  {
    code = Totp.code_at r ~unix_time;
    seconds_left = Totp.seconds_left r ~unix_time;
  }

let rename ?issuer ?account ~domain ~engine ~lazy_tree ~id t =
  let ctx = context ~writing:true ~domain ~engine ~lazy_tree t in
  let r = find ctx id in
  let r =
    {
      r with
      issuer = Option.fold ~none:r.issuer ~some:String.trim issuer;
      account = Option.fold ~none:r.account ~some:String.trim account;
      modified = now ();
    }
  in
  if r.issuer = "" && r.account = "" then
    Fail.invalid "issuer and account cannot both be empty";
  write ctx ~exclusive:false id r

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
let import ~domain ~engine ~lazy_tree t text : Protocol.totp_imported =
  let ctx = context ~writing:true ~domain ~engine ~lazy_tree t in
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
                write ctx ~exclusive:true (Ids.token ()) r;
                known := r :: !known;
                incr added)
        (entries line))
    (String.split_on_char '\n' text);
  { added = !added; already = !already; refused = List.rev !refused }

let export ~domain ~engine ~lazy_tree t passphrase =
  let ctx = context ~domain ~engine ~lazy_tree t in
  Vault.confirm ~domain ~engine ~lazy_tree t passphrase;
  let ok, corrupt = records ctx in
  let uris =
    ok
    |> List.sort (fun (a, (x : Totp.t)) (b, (y : Totp.t)) ->
        compare (x.issuer, x.account, a) (y.issuer, y.account, b))
    |> List.map (fun (_, r) -> Totp.to_uri r)
  in
  { Protocol.uris; corrupt }
