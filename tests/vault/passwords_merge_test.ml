(* format-merge §7: the suitability of passwords-records, through the merge kit. *)
open Tsync_vault

let key = String.make 32 'k'
let key_id = "0123456789abcdef"

module Passwords_records = struct
  type record = Passwords.t

  let name = "passwords-records"

  let read (f : Fold.file) =
    match Envelope.open_ ~key ~key_id ~extension:"passwords" f.body with
      | Ok plaintext -> Result.to_option (Passwords.of_string plaintext)
      | Error _ -> None

  let fold =
    Fold.grouped ~open_:read ~key:Passwords.key_fields
      ~modified:Passwords.modified

  let generate ~seed : Passwords.t =
    Login
      {
        title = Printf.sprintf "Site %d" seed;
        urls = [Printf.sprintf "https://site%d.example" seed];
        username = "me@example.com";
        password = Printf.sprintf "password %06d" seed;
        notes = "";
        totp = "";
        fields = [];
        modified = 1760500000;
        unknown = [];
      }

  let mergeable ~seed = function
    | Passwords.Login l ->
        Passwords.Login
          {
            l with
            title = Printf.sprintf "Renamed %d" seed;
            modified = l.modified + 60;
          }
    | r -> r

  let conflicting ~seed = function
    | Passwords.Login l ->
        Passwords.Login { l with password = Printf.sprintf "changed %06d" seed }
    | r -> r

  let file ~name r =
    {
      Fold.name;
      body =
        Envelope.seal ~key ~key_id ~extension:"passwords"
          (Passwords.to_string r);
    }

  let change = function
    | Passwords.Login l ->
        Printf.sprintf "%s/%s/%s" l.title l.username l.password
    | Note n -> n.title
    | Passkey p -> p.rp_id

  let scale = [(1000, 10., 128); (10000, 120., 1024)]
end

module Suite = Tsync_merge_kit.Merge_kit.Make (Passwords_records)

let () = Suite.run ()
