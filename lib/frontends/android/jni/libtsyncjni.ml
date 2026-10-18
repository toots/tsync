(* The library's OCaml entry: linking the bridge registers its entries; the
   log sink is the platform's (android §4.1). *)
external log_write : int -> string -> unit = "tsync_log_write"

let () =
  Atomic.set Tsync_core.Log.sink (fun level message ->
      log_write
        (match level with Debug -> 0 | Info -> 1 | Warn -> 2 | Err -> 3)
        message)

exception Keystore_failure of string

external keystore_put : string -> string -> unit = "tsync_keystore_put"
external keystore_get : string -> string option = "tsync_keystore_get"
external keystore_delete : string -> unit = "tsync_keystore_delete"

(* The entry is the key id, then K. This library is only ever the app's, so
   registering at load reaches no test's keystore. *)
let key_id_length = 16

let keystore f =
  try f ()
  with Keystore_failure reason ->
    Tsync_core.Fail.raise_ Refused "the Android Keystore: %s" reason

let () =
  Callback.register_exception "tsync_keystore_failure" (Keystore_failure "");
  Tsync_owner.Keystore.register
    {
      name = "the Android Keystore";
      put =
        (fun ~domain ~key_id ~key ->
          (* get splits the entry at this length. *)
          if String.length key_id <> key_id_length then
            Tsync_core.Fail.invalid "a key id is %d characters" key_id_length;
          keystore (fun () -> keystore_put domain (key_id ^ key)));
      get =
        (fun ~domain ->
          keystore (fun () ->
              Option.bind (keystore_get domain) (fun entry ->
                  let length = String.length entry in
                  if length <= key_id_length then None
                  else
                    Some
                      ( String.sub entry 0 key_id_length,
                        String.sub entry key_id_length (length - key_id_length)
                      ))));
      delete = (fun ~domain -> keystore (fun () -> keystore_delete domain));
    }
