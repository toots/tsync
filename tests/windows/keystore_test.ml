(* The vault keystore in Credential Manager (security-model §10.6), through the
   interface the owner uses. *)

open Tsync_core

let p fmt = Printf.printf fmt

let () =
  Tsync_credential_manager.Credential_manager.register ();
  let ks = Option.get (Tsync_owner.Keystore.registered ()) in
  let name = Printf.sprintf "tsync-test-%d:x" (Pid.self ()) in
  let other = name ^ ":with" in
  let show label domain =
    p "%-36s %s\n" label
      (match ks.get ~domain with
        | Some (id, key) -> Printf.sprintf "%s %S" id key
        | None -> "none")
  in
  p "keystore: %s\n" ks.name;
  show "nothing stored" name;
  ks.put ~domain:name ~key_id:"0001" ~key:"first";
  show "after a put" name;
  ks.put ~domain:name ~key_id:"0002" ~key:"second";
  show "after a put of another key id" name;
  ks.put ~domain:other ~key_id:"0003" ~key:"other";
  show "a name its prefix starts" other;
  show "the first name, untouched" name;
  ks.delete ~domain:name;
  show "after a delete" name;
  show "the other name, untouched" other;
  ks.delete ~domain:other;
  show "the other, deleted" other
