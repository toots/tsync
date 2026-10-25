(** A machine's entry in the vault's machine list (vault §6.3), sealed under K
    at [/.tsync-ext/vault/machines/<client uuid>]: [name], the host's unless the
    user gave another; [enrolled] and [last_unlock]; [seen], the client uuids of
    the entries this machine has acknowledged, so any other is reported as new;
    [modified]. Times are seconds since the epoch. *)
type t = {
  name : string;
  enrolled : int;
  last_unlock : int;
  seen : string list;
  modified : int;
  unknown : (string * Yojson.Safe.t) list;
}

val to_string : t -> string

(** [Error] for a body that is not an entry. *)
val of_string : string -> (t, string) result
