(** The failure model (spec failure-model §3–§7): one kind per failure, decided
    by the layer with the evidence and carried as data. Stopping is
    {!Stop.Stopping} and cancellation {!Rt.Cancelled}. *)

type kind =
  | Absent  (** an authority answered that the object does not exist *)
  | Exists  (** the name is held by something else *)
  | Not_empty
  | Denied
  | Read_only
  | Refused  (** a permanent refusal of another kind *)
  | Invalid  (** a malformed request on this side *)
  | Corrupt  (** an answer that contradicts what it must be *)
  | Missing_chunks of string list  (** the reference gate's refusal *)
  | Paused
  | Unprepared  (** local state cannot express the operation yet *)
  | Link  (** transient: no answer, a stall, a dropped connection *)
  | Load  (** transient: the authority answered "later" *)
  | Local  (** transient: a resource on this host *)
  | Unreachable  (** derived: nothing that could answer is up *)
  | Deadline  (** a waiter's bound expired; the work may continue *)
  | Unexplained

type t = {
  kind : kind;
  op : string;
  reason : string;  (** one sentence, safe to show a user *)
  repair : string option;
  retry_after : float option;
  stalled : bool;
      (** a wait that heard nothing for its whole bound: what the uplink
          governor counts as a timeout *)
}

exception E of t

val make :
  ?repair:string ->
  ?retry_after:float ->
  ?stalled:bool ->
  ?op:string ->
  kind ->
  string ->
  t

val raise_ :
  ?repair:string ->
  ?retry_after:float ->
  ?stalled:bool ->
  ?op:string ->
  kind ->
  ('a, unit, string, 'b) format4 ->
  'a

val absent : ?op:string -> ('a, unit, string, 'b) format4 -> 'a
val invalid : ?op:string -> ('a, unit, string, 'b) format4 -> 'a
val corrupt : ?op:string -> ('a, unit, string, 'b) format4 -> 'a
val is_absent : exn -> bool

(** Lowercase "kind/subkind", the spelling of a record's [lastError]. *)
val kind_name : kind -> string

val retryable : kind -> bool
val to_string : t -> string

(** The local filesystem table of §4.1. *)
val kind_of_errno : Unix.error -> kind

val of_unix : ?op:string -> Unix.error -> string -> string -> t

(** Classify any exception; never produces {!Absent} from something that is not
    an explicit absence. Callers re-raise stops and cancellations first. *)
val classify : ?op:string -> exn -> t

(** The client error code of §7.2. *)
val code : kind -> string

val kind_of_code : string -> kind

(** The [x-tsync-kind] value of a permanent kind on the peer wire. *)
val wire_kind : kind -> string option

val of_wire_kind : string -> kind

(** The errno a POSIX frontend answers (§7.3). *)
val errno : kind -> Unix.error
