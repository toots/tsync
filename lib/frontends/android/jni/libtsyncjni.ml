(* The library's OCaml entry: linking the bridge registers its entries; the
   log sink is the platform's (android §4.1). *)
external log_write : int -> string -> unit = "tsync_log_write"

let () =
  Atomic.set Tsync_core.Log.sink (fun level message ->
      log_write
        (match level with Debug -> 0 | Info -> 1 | Warn -> 2 | Err -> 3)
        message)
