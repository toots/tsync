(* extensions README §4: an extension's records in its folder, opened under the
   vault's K, settled by its format merge before a verb reads them, written
   sealed. What every extension shares; each instantiates it with its record. *)
open Tsync_core
module Fold = Tsync_vault.Fold
module Envelope = Tsync_vault.Envelope

module type RECORD = sig
  type t

  (** The extension. *)
  val name : string

  val of_string : string -> (t, string) result
  val to_string : t -> string

  (** The grouped fold's key fields (README §4.3). *)
  val key_fields : t -> string

  val modified : t -> int

  (** The record kept from a conflicted copy, labelled with [suffix]; [None]
      when its label already ends with it. *)
  val relabel : suffix:string -> t -> t option
end

module Make (R : RECORD) = struct
  let name = R.name
  let folder = Names.join Names.extension_root name

  let check_uses ~(domain : Tsync_domain.Domain.t) ~engine =
    if not (List.mem name (Vault.extensions ~domain ~engine)) then
      Fail.invalid "%s does not use %s: add it to its extensions in the config"
        (Domain_name.to_string domain.name)
        name

  type ctx = {
    engine : (module Tsync_sync.Engine.S);
    key : string;
    key_id : string;
    opened : (string, R.t option) Hashtbl.t;
        (** by body: a verb opens each body once, the fold's included *)
    keep : bool;  (** a lazy tree: bodies read stay pinned (README §4.1) *)
    writable : bool;  (** format-merge §2: a fold is applied only then *)
  }

  let opened ctx (f : Fold.file) =
    match Hashtbl.find_opt ctx.opened f.body with
      | Some r -> r
      | None ->
          let r =
            match
              Envelope.open_ ~key:ctx.key ~key_id:ctx.key_id ~extension:name
                f.body
            with
              | Ok plaintext -> Result.to_option (R.of_string plaintext)
              | Error _ -> None
          in
          Hashtbl.replace ctx.opened f.body r;
          r

  let seal ctx record =
    Envelope.seal ~key:ctx.key ~key_id:ctx.key_id ~extension:name
      (R.to_string record)

  (* totp §3: a record moved from a conflicted copy to a digest id (rule 5)
     says the client it came from. A write after the fold, which sealing makes
     no function of the bytes; concurrent relabels write the same plaintext. *)
  let relabel ctx = function
    (* A copy's name starts with its record id: rule 4 moves it back there. *)
    | Fold.Move { src; dst }
      when Fold.copied_from src <> None && dst <> String.sub src 0 32 -> (
        let client = Option.get (Fold.copied_from src) in
        let suffix = Printf.sprintf " (conflicted copy from %s)" client in
        let path = Names.join folder dst in
        let file =
          { Fold.name = dst; body = Vault.read_file ctx.engine path }
        in
        match Option.bind (opened ctx file) (R.relabel ~suffix) with
          | Some r ->
              Format_merge.write_file ctx.engine ~exclusive:false path
                (seal ctx r)
          | None -> ())
    | _ -> ()

  (* README §4.3, run before a verb reads: what a fold settles is never shown
     twice. *)
  let settled ctx =
    let read () = Vault.files ~keep:ctx.keep ctx.engine folder in
    match
      Format_merge.settle_folder ~after:(relabel ctx) ~writable:ctx.writable
        ~read
        ~fold:
          (Fold.grouped ~open_:(opened ctx) ~key:R.key_fields
             ~modified:R.modified)
        ctx.engine folder
    with
      | Some files -> files
      | None -> read ()

  (* README §4.1: a read answers the last view of the vault's folders and this
     one; a write proceeds on it, pushed later. *)
  let context ?(writing = false) ?use ~domain ~engine ~lazy_tree t =
    check_uses ~domain ~engine;
    let keyring, key = Vault.held ?use ~domain ~engine ~lazy_tree t in
    if lazy_tree then (
      let (module E : Tsync_sync.Engine.S) = engine in
      if not writing then
        Vault.read_folders engine t (Vault.vault_folders @ [folder])
        (* The first record makes the folder: nothing to pull yet. *)
      else if E.kind folder = `Dir then Vault.before_write t folder);
    {
      engine;
      key;
      key_id = keyring.Tsync_vault.Keyring.key_id;
      opened = Hashtbl.create 16;
      keep = lazy_tree;
      writable = not domain.Tsync_domain.Domain.domain.read_only;
    }

  let now () = int_of_float (Unix.time ())

  let write ctx ~exclusive id record =
    let (module E : Tsync_sync.Engine.S) = ctx.engine in
    List.iter
      (fun dir -> E.mkdir dir ~exclusive:false)
      [Names.extension_root; folder];
    Format_merge.write_file ctx.engine ~exclusive (Names.join folder id)
      (seal ctx record)

  (* Records that open, by id, and the ids that do not. *)
  let records ctx =
    List.fold_left
      (fun (ok, corrupt) (f : Fold.file) ->
        if not (Fold.is_record_id f.name) then (ok, corrupt)
        else (
          match opened ctx f with
            | Some r -> ((f.name, r) :: ok, corrupt)
            | None -> (ok, f.name :: corrupt)))
      ([], []) (settled ctx)
    |> fun (ok, corrupt) -> (List.rev ok, List.sort compare corrupt)

  let find ctx id =
    if not (Fold.is_record_id id) then Fail.invalid "%S is not a record id" id;
    let ok, corrupt = records ctx in
    match List.assoc_opt id ok with
      | Some r -> r
      | None when List.mem id corrupt ->
          Fail.corrupt "%s does not open under this vault's key" id
      | None -> Fail.absent "no record %s" id

  (* Removing needs no plaintext, so a record that does not open goes too. *)
  let remove ~domain ~engine ~lazy_tree t id =
    let ctx = context ~writing:true ~domain ~engine ~lazy_tree t in
    (match find ctx id with
      | _ -> ()
      | exception Fail.E { kind = Corrupt; _ } -> ());
    let (module E : Tsync_sync.Engine.S) = engine in
    E.delete (Names.join folder id)

  (* README §4.2: the fold that waited for the key. *)
  let fold ~domain ~engine ~lazy_tree t =
    if List.mem name (Vault.extensions ~domain ~engine) then
      ignore (records (context ~use:false ~domain ~engine ~lazy_tree t))
end
