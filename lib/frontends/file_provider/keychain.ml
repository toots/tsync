open Tsync_core

(* security-model §10.6: the item holds the key id, then K. *)
external put : string -> string -> unit = "tsync_keychain_put"
external get : string -> string option = "tsync_keychain_get"
external delete : string -> unit = "tsync_keychain_delete"
external no_dialogs : unit -> unit = "tsync_keychain_no_dialogs"

let key_id_length = 16

let keychain f =
  try f () with Failure reason -> Fail.raise_ Refused "keychain: %s" reason

(* By the host as it starts its owner, never at load: a test linking this
   library must not reach the user's keychain. *)
let register () =
  no_dialogs ();
  Tsync_owner.Keystore.register
    {
      name = "the login keychain";
      put =
        (fun ~domain ~key_id ~key ->
          keychain (fun () -> put domain (key_id ^ key)));
      get =
        (fun ~domain ->
          keychain (fun () ->
              Option.bind (get domain) (fun entry ->
                  if String.length entry <= key_id_length then None
                  else
                    Some
                      ( String.sub entry 0 key_id_length,
                        String.sub entry key_id_length
                          (String.length entry - key_id_length) ))));
      delete = (fun ~domain -> keychain (fun () -> delete domain));
    }
