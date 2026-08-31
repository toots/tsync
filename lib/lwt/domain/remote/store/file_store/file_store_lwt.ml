(* Applied once: the debouncer in front of a domain's cursor is per object, so
   every module touching the journal shares one. *)
module Manifests = struct
  module Make (C : Conf_lwt.S) = Store_lwt.Make (C) (Layout_lwt.Inode.Make (C))
end

include File_store

module Base =
  File_store.Over (Io_lwt.Core) (Io_lwt.Lock) (Io_lwt.Clock) (Manifests)

(* The journal, and the copy of it this client keeps.

   Every entry this client publishes is written to {!Applied_entries} on its way
   out, and every entry it applies from a peer is written there by whoever
   applied it. Here rather than at each publisher — there are five, and one
   added later would be one the change feed never hears about.

   Kept before the entry is published, not after: by the time a publisher gets
   this far the change is already in the mirror, so an entry recorded and not
   published describes something that did happen, while one published and not
   recorded is a change this client can no longer report at all. *)
module Make (C : Conf_lwt.S) = struct
  include Base.Make (C)
  module J = Journal.Make (C)
  open Lwt.Syntax

  let note_applied entry_key ops =
    Applied_entries.note ~cache_root:C.cache_root ~domain_name:C.domain_name
      entry_key ops

  (* Minted here when the caller named none, so the key is known before the
     entry goes out and both records carry the same one. *)
  let entry_key_of = function Some k -> k | None -> J.entry_key ()

  let write_journal_entry ?entry_key ops =
    let entry_key = entry_key_of entry_key in
    let* () = note_applied entry_key ops in
    write_journal_entry ~entry_key ops

  (* The bulk path an import takes. The body is the entry's own encoding, so the
     ops are read back from it rather than passed a second way. *)
  let write_journal_entry_body ?entry_key body =
    let entry_key = entry_key_of entry_key in
    let* () =
      note_applied entry_key (Journal.decode (Bigstring.to_string body))
    in
    write_journal_entry_body ~entry_key body
end
