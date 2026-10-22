(** A vault's mark as dbusmenu draws it (spec frontends/linux-tray.md §6.5,
    vault §8.1): PNG bytes for a code row's [icon-data]. *)

(** tsync's glyph filled with a [#rrggbb] colour, at {!side} pixels; [None] for
    any other spelling. *)
val glyph : string -> string option

val side : int
