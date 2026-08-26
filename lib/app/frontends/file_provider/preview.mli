(** A small picture of a file, made the way the Finder makes one.

    In the daemon rather than the app that shows it: the menu bar app is
    sandboxed, and a file in the shared container is "data from other apps" to
    it. QuickLook's generators cover cover art, poster frames, documents and
    images alike, so nothing here knows one format from another. *)

(** [of_file ~scratch ~name path] is a PNG of [path], or [None] for a file
    QuickLook can make no picture of.

    [name] supplies the extension QuickLook types the file by, which [path]
    lacks — a staged body is named by uuid. [scratch] is a directory on the same
    filesystem, holding the briefly-linked name. Never raises: a file with no
    preview is not a failure. *)
val of_file : scratch:string -> name:string -> string -> string option Lwt.t
