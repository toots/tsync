(* format-merge §7: the suitability of totp-records, through the merge kit. *)
open Tsync_vault

let key = String.make 32 'k'
let key_id = "0123456789abcdef"

module Totp_records = struct
  type record = Totp.t

  let name = "totp-records"

  let read (f : Fold.file) =
    match Envelope.open_ ~key ~key_id ~extension:"totp" f.body with
      | Ok plaintext -> Result.to_option (Totp.of_string plaintext)
      | Error _ -> None

  let fold =
    Fold.grouped ~open_:read ~key:Totp.code_fields
      ~modified:(fun (r : Totp.t) -> r.modified)

  let generate ~seed : Totp.t =
    {
      issuer = Printf.sprintf "Issuer %d" seed;
      account = "me@example.com";
      secret = Totp.base32_encode (Printf.sprintf "seed-%06d" seed);
      algorithm = `SHA1;
      digits = 6;
      period = 30;
      modified = 1760500000;
      unknown = [];
    }

  let mergeable ~seed (r : Totp.t) =
    {
      r with
      account = Printf.sprintf "renamed-%d" seed;
      modified = r.modified + 60;
    }

  let conflicting ~seed (r : Totp.t) =
    { r with secret = Totp.base32_encode (Printf.sprintf "other-%06d" seed) }

  let file ~name r =
    {
      Fold.name;
      body = Envelope.seal ~key ~key_id ~extension:"totp" (Totp.to_string r);
    }

  let change (r : Totp.t) =
    Printf.sprintf "%s/%s/%s" r.issuer r.account r.secret

  let scale = [(1000, 5., 64); (10000, 60., 512)]
end

module Suite = Tsync_merge_kit.Merge_kit.Make (Totp_records)

let () = Suite.run ()
