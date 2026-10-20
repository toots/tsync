(* passwords/browser §5: [None] when the user was verified, else the reason. *)
external verify : string -> string option = "tsync_local_auth_verify"

let () =
  Tsync_owner.Verifier.register
    {
      name = "LocalAuthentication";
      verify =
        (fun ~reason ->
          match verify reason with None -> Ok () | Some why -> Error why);
    }
