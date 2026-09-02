include File_store

module Base =
  File_store.Over (Io_lwt.Core) (Io_lwt.Lock) (Io_lwt.Clock) (Store_lwt.Inode)

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
  module Lk = Logical_key.Make (C)
  open Lwt.Syntax

  (* Recording a change and announcing it are one operation. Two would mean
     every caller that mutates a domain is trusted to remember the second, and
     the ones outside the daemon -- an import, a revert -- did not: the entry
     was kept and the change feed would have answered with it, but nothing told
     a frontend to ask, so it stayed invisible until something else happened to
     look.

     Batched and best-effort on {!Change_notice}'s terms: a frontend that is
     down is the ordinary case, and a catch-up of a hundred thousand entries
     must not be a hundred thousand round trips. The daemon publishing its own
     uploads notifies its own socket, which is one round trip per batch and one
     code path rather than two. *)
  let announce ops =
    List.iter
      (fun op ->
        List.iter
          (fun rel ->
            Change_notice.send ~domain:C.domain_name ~sockets:[C.socket_path]
              (Logical_key.to_string (Lk.file rel)))
          (Journal.keys_of_op op))
      ops

  let note_applied entry_key ops =
    Applied_entries.note ~cache_root:C.cache_root ~domain_name:C.domain_name
      entry_key ops

  let applied_keys () =
    Applied_entries.keys ~cache_root:C.cache_root ~domain_name:C.domain_name

  (* Minted here when the caller named none, so the key is known before the
     entry goes out and both records carry the same one. *)
  let entry_key_of = function Some k -> k | None -> J.entry_key ()

  let write_journal_entry ?entry_key ops =
    let entry_key = entry_key_of entry_key in
    let* () = note_applied entry_key ops in
    let+ published = write_journal_entry ~entry_key ops in
    announce ops;
    published

  (* The bulk path an import takes. The body is the entry's own encoding, so the
     ops are read back from it rather than passed a second way. *)
  let write_journal_entry_body ?entry_key body =
    let entry_key = entry_key_of entry_key in
    let ops = Journal.decode (Bigstring.to_string body) in
    let* () = note_applied entry_key ops in
    let+ published = write_journal_entry_body ~entry_key body in
    announce ops;
    published
end
