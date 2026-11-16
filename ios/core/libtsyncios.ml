(* The object's OCaml entry: linking the bridge registers its entries; the log
   sink is the unified log and the core log (ios §4). *)
external log_write : int -> string -> unit = "tsync_ios_log_write"

let () =
  Atomic.set Tsync_core.Log.min_level Info;
  Atomic.set Tsync_core.Log.sink (fun level message ->
      log_write
        (match level with Debug -> 0 | Info -> 1 | Warn -> 2 | Err -> 3)
        message)

(* ios §4: the core log shows when the system started a process. *)
let () = Tsync_core.Log.info "core started"

(* ios §2: the system kills a suspended extension that holds a file lock. *)
let () = Tsync_owner.Owner.use_records ()

(* ios.md §4.1: in the File Provider extension, which owns the domains, the
   keychain is the keystore and the app derives every key. The app's process
   never calls it. *)
let () =
  Callback.register "tsync_ios_owner_host" (fun service ->
      try
        Tsync_keychain.Keychain.register ~name:"the keychain" ~service ();
        Tsync_owner.Vault.no_derivation ();
        ""
      with e -> Printexc.to_string e)
