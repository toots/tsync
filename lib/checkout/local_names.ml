open Tsync_core

let flag dir = Filename.concat dir ".tsync-demoted"
let dir_marker dir = Filename.concat dir ".tsync-dir"
let name_marker dir = Filename.concat dir ".tsync-name"

(* local-names §3: a name the disk refuses is unstorable there. *)
let eilseq = if Fs.is_macos then 92 else 84

let refused = function
  | Unix.ENAMETOOLONG | Unix.EINVAL -> true
  | Unix.EUNKNOWNERR n -> n = eilseq
  | _ -> false

let raise_unix e fn arg = raise (Fail.E (Fail.of_unix e fn arg))

let lookup p =
  match Fs.eintr (fun () -> Unix.LargeFile.lstat p) with
    | st -> Some st
    | exception Unix.Unix_error ((ENOENT | ENOTDIR), _, _) -> None
    | exception Unix.Unix_error (e, _, _) when refused e -> None
    | exception Unix.Unix_error (e, fn, arg) -> raise_unix e fn arg

let same (a : Unix.LargeFile.stats) (b : Unix.LargeFile.stats) =
  a.st_dev = b.st_dev && a.st_ino = b.st_ino

(* No entry or marker is empty, so an empty file is a probe (§4). *)
let is_probe (st : Unix.LargeFile.stats) = st.st_kind = S_REG && st.st_size = 0L

let folder_name p =
  Option.bind
    (Fs.read_file_opt (dir_marker p))
    (fun b ->
      match Folder.classify_marker b with
        | `Marker (m : Folder.marker) -> Some m.name
        | _ -> None)

(* §3.1: the record, never the listed spelling. *)
let recorded p (st : Unix.LargeFile.stats) =
  match st.st_kind with
    | S_DIR -> (
        match folder_name p with
          | Some n -> Some n
          | None -> Fs.read_file_opt (name_marker p))
    | S_REG ->
        Option.map
          (fun (m : Manifest.t) -> m.name)
          (Option.bind (Fs.read_file_opt p) Manifest.decode)
    | _ -> None

(* An entry with no record files the name its listing gives. *)
let listed dir st =
  List.find_opt
    (fun l ->
      match lookup (Filename.concat dir l) with
        | Some s -> same s st
        | None -> false)
    (Fs.readdir dir)

let name_of dir local st =
  match recorded (Filename.concat dir local) st with
    | Some n -> Some n
    | None -> listed dir st

let name_at dir local =
  match lookup (Filename.concat dir local) with
    | Some st when not (is_probe st) -> name_of dir local st
    | _ -> None

let holds dir local n = name_at dir local = Some n

(* [slot_of] finds a folder whose markers were rewritten for a move that the
   rename did not follow. *)
(* The plain slot is looked at again after the handle: a promotion between
   the first two lookups would otherwise read as absent (§6). *)
let find ?slot_of dir n =
  let s = Option.value ~default:n slot_of in
  let plain () = Names.storable s && holds dir s n in
  if plain () then Some s
  else if holds dir (Names.handle s) n then Some (Names.handle s)
  else if plain () then Some s
  else None

let set_flag dir =
  if not (Fs.exists (flag dir)) then Fs.durable_replace (flag dir) "demoted"

(* Escaped entries filing a storable name: the only ones a promotion moves. *)
let demoted dir =
  List.filter_map
    (fun local ->
      if String.starts_with ~prefix:Names.escape_prefix local then (
        match name_at dir local with
          | Some m when Names.storable m && Names.handle m = local -> Some m
          | _ -> None)
      else None)
    (Fs.readdir dir)

let reaches dir m st =
  match lookup (Filename.concat dir m) with
    | Some s -> same s st
    | None -> false

(* The probe of n's plain slot; [None] when an entry holds it. *)
let probe dir n =
  let p = Filename.concat dir n in
  match
    Fs.eintr (fun () -> Unix.openfile p [O_WRONLY; O_CREAT; O_EXCL] 0o600)
  with
    | fd ->
        Fs.close fd;
        lookup p
    | exception Unix.Unix_error (Unix.EEXIST, _, _) -> (
        match lookup p with Some st when is_probe st -> Some st | _ -> None)
    | exception Unix.Unix_error (e, _, _) when refused e -> None
    | exception Unix.Unix_error (e, fn, arg) -> raise_unix e fn arg

(* §4–§5: after n's plain holder left, the least demoted member of its class
   takes the plain slot. The flag goes once nothing is demoted. *)
let promote dir n =
  if Names.storable n && Fs.exists (flag dir) then (
    match probe dir n with
      | None -> ()
      | Some st ->
          let demoted = demoted dir in
          let members = List.filter (fun m -> reaches dir m st) demoted in
          ignore (Fs.release (Filename.concat dir n));
          (match List.sort String.compare members with
            | m :: _ ->
                Fs.rename
                  (Filename.concat dir (Names.handle m))
                  (Filename.concat dir m)
            | [] -> ());
          if List.length demoted <= Bool.to_int (members <> []) then
            ignore (Fs.release (flag dir));
          Fs.fsync_dir dir)

(* [None] when the disk refuses the name. *)
let rename_into ~from dir local =
  match
    Fs.eintr (fun () -> Fs.unix_rename from (Filename.concat dir local))
  with
    | () -> Some local
    | exception Unix.Unix_error (e, _, _) when refused e -> None
    | exception Unix.Unix_error (e, fn, arg) -> raise_unix e fn arg

let check_free dir local n =
  match name_at dir local with
    | Some other when other <> n ->
        Fail.raise_ Fail.Exists "%s: its local name is held by %S" n other
    | _ -> ()

(* A directory that moves to its handle carries its name (04 §2.3). *)
let keep_name p n (st : Unix.LargeFile.stats) =
  if st.st_kind = S_DIR && not (Fs.exists (name_marker p)) then
    Fs.durable_replace (name_marker p) n

let rec settle dir ~from n =
  let escaped ~demoted =
    let h = Names.handle n in
    check_free dir h n;
    if demoted then set_flag dir;
    Option.get (rename_into ~from dir h)
  in
  let plain () =
    match rename_into ~from dir n with
      | Some l -> l
      | None -> escaped ~demoted:false
  in
  if not (Names.storable n) then escaped ~demoted:false
  else (
    let slot = Filename.concat dir n in
    match lookup slot with
      | None -> plain ()
      | Some st when is_probe st ->
          (* A removal that did not finish (§4). *)
          if Fs.exists (flag dir) then promote dir n
          else ignore (Fs.release slot);
          settle dir ~from n
      | Some st when Option.fold ~none:false ~some:(same st) (lookup from) ->
          (* A rename within its own class (§5). *)
          let rest =
            if Fs.exists (flag dir) then
              List.filter (fun m -> m <> n && reaches dir m st) (demoted dir)
            else []
          in
          if List.exists (fun m -> String.compare m n < 0) rest then (
            let l = escaped ~demoted:true in
            promote dir n;
            l)
          else plain ()
      | Some st -> (
          match name_of dir n st with
            | Some m when m <> n && String.compare n m > 0 ->
                escaped ~demoted:true
            | Some m when m <> n -> (
                (* m's own spelling, so an undo gives it back unchanged. *)
                let slot = Filename.concat dir m in
                let hm = Filename.concat dir (Names.handle m) in
                check_free dir (Names.handle m) m;
                keep_name slot m st;
                set_flag dir;
                Fs.rename slot hm;
                (* What follows the demotion is one rename; a failure undoes it. *)
                let undo () = Fs.rename hm slot in
                match rename_into ~from dir n with
                  | Some l -> l
                  | None ->
                      undo ();
                      Fail.raise_ Fail.Unexplained
                        "%s: refused after a lookup reached it" n
                  | exception e ->
                      undo ();
                      raise e)
            | _ -> plain ()))

let place ?(durable = true) dir ~from n =
  let l = settle dir ~from n in
  if durable then Fs.fsync_dir dir;
  l

let remove dir n ~drop =
  Option.iter (fun l -> drop (Filename.concat dir l)) (find dir n);
  promote dir n
