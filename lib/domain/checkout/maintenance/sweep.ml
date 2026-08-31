(** What every sweep of the file layer answers with, and when one runs.

    Kept apart from the sweeps themselves so each can name it without the
    aggregator that lists them depending on it in turn. *)

(** What a sweep collected. Bytes are the file bytes freed, which is what a
    caller reporting to a person wants; [files] is what says whether anything
    happened at all. *)
type swept = { files : int; bytes : int }

let nothing = { files = 0; bytes = 0 }
let add a b = { files = a.files + b.files; bytes = a.bytes + b.bytes }

(** When a sweep runs. The whole point of naming it: a reader asking "when does
    this happen" reads the task list rather than hunting for the call site.

    [`After_upload] is separate from [`Periodic] because growth caused by this
    process is worth answering promptly, where a periodic pass is what catches
    growth nothing here caused. *)
type trigger =
  [ `Periodic of float  (** seconds between runs *)
  | `After_upload
  | `On_demand  (** a command asks; nothing schedules it *) ]

let trigger_name = function
  | `Periodic s -> Printf.sprintf "every %.0fs" s
  | `After_upload -> "after each upload"
  | `On_demand -> "on demand"
