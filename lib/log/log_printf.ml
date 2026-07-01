let implementation = "printf"
let init () = ()

let log _level fmt =
  Printf.ksprintf (fun msg -> Printf.eprintf "%s\n%!" msg) fmt

let debug fmt = log `debug fmt
let info fmt = log `info fmt
let warn fmt = log `warn fmt
let err fmt = log `err fmt
