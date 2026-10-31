(** Which domain leaves a sync root shows (cloud-files §7). The host's apply,
    listing callback and take ask it; it never touches the disk. *)

(** Why a leaf is not shown. *)
type reason =
  [ `Unpresentable of string  (** §7.1, the rule it breaks *)
  | `Case_group of string  (** §7.2, the sibling shown instead *) ]

(** The name a leaf is shown under, its bytes decoded as UTF-8 with replacement
    characters, or why Windows cannot hold it (§7.1). *)
val presentable : string -> (string, string) result

(** The presented children of one folder and the others, each with its reason.
    [fold] maps a name to its form under the volume's case mapping; [on_disk]
    says whether the sync root holds that exact name, so the member the user
    already has stays shown (§7.2). The presented keep their input order. *)
val choose :
  fold:(string -> string) ->
  on_disk:(string -> bool) ->
  (string * 'a) list ->
  ('a * string) list * ('a * reason) list
