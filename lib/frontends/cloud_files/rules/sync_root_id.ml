open Tsync_core

let prefix ~sid = "tsync!" ^ sid ^ "!"

let id ~sid name =
  prefix ~sid ^ Xxh.hex16 (Xxh.string ~seed:0L (Domain_name.to_string name))
