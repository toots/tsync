external nofile_current : unit -> int = "tsync_nofile_current"
external nofile_raise : int -> int = "tsync_nofile_raise"

let current () = match nofile_current () with -1 -> None | n -> Some n
let raise_to ~target = nofile_raise target
