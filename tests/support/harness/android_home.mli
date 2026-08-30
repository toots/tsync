(** Pointing a tsync at a scratch home, and asking it what that means.

    [HOME] alone does not decide where the binary looks: [XDG_CONFIG_HOME] and
    its neighbours take precedence on Linux and a CI runner sets them, so a test
    that only exports [HOME] reads the runner's own config rather than its own —
    and passes on a developer's machine, where they are unset.

    Where a binary pointed at a home keeps its things is asked of the binary
    rather than assumed: the layout is the platform's, XDG on Linux and a group
    container on macOS, and a test that spells one of them out is a test for one
    platform. *)
type paths = { config : string; cache : string }

(** The shell prefix that puts a spawned binary in [home]. *)
val env : home:string -> string

(** The same for this process, for a test that calls in rather than spawning. *)
val adopt : home:string -> unit

(** [paths ~tsync ~home ~scratch] asks [tsync] where it would keep its config
    and its cache under [home], using [scratch] for the answer. *)
val paths : tsync:string -> home:string -> scratch:string -> paths
