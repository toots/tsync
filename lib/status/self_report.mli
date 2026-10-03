(** A process's description of itself for the status report (spec 07 §5.5). *)

(** A counter's growth per second since the previous sample (07 §5.5): the first
    sample averages since [now] at creation, and samples under a second apart
    reuse the last rate. *)
type rate

val rate : now:float -> rate
val per_second : rate -> now:float -> float -> float

val self :
  ?traffic:Status_report.traffic ->
  ?listener:Status_report.listener ->
  role:string ->
  serves:string list ->
  unit ->
  Status_report.self
