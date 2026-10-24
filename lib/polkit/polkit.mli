(** passwords/linux §4: the Linux platform verifier, polkit's
    [CheckAuthorization] for [org.feverdreamtv.tsync.verify-user], which the
    packages install as [auth_self]. The browser host calls {!register} at
    start; each verification then asks polkit on the system bus, whose agent
    shows the desktop's dialog. *)

(** What polkit answered: [`No_agent] when it needed a dialog and no agent of
    the caller's session could show one. *)
type answer = [ `Authorized | `Dismissed | `Refused | `No_agent ]

(** Asks once, blocking while the user answers. Raises [Fail.E] [Unreachable]
    when polkit cannot be asked: no bus, no authority, the action not installed.
*)
val check : address:string -> answer

(** Registers the verifier when libdbus loads and the action file is installed.
    Its [verify] raises [Fail.E] [Unreachable] on [`No_agent] or when polkit
    cannot be asked, which the extension answers with the passphrase. *)
val register : unit -> unit
