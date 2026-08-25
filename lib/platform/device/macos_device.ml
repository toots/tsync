(* Nothing publishes a queue depth the way sysfs does, and reaching the
   equivalent means IOKit and C stubs. [diskutil] already asks IOKit and prints
   the answer, so this reads that: one subprocess, once per store, at start-up.

   It answers with a category, not a number, so the figures below judge classes
   of device rather than measuring this one. Being wrong high costs requests
   queueing at the device instead of in front of it, so uncertain cases lean
   low. *)

let field name line =
  match String.index_opt line ':' with
    | Some i when String.trim (String.sub line 0 i) = name ->
        Some
          (String.trim (String.sub line (i + 1) (String.length line - i - 1)))
    | _ -> None

let run command =
  match Unix.open_process_in (command ^ " 2>/dev/null") with
    | exception _ -> []
    | ic ->
        let lines = ref [] in
        (try
           while true do
             lines := input_line ic :: !lines
           done
         with End_of_file -> ());
        ignore (Unix.close_process_in ic);
        List.rev !lines

(* [diskutil] takes only a mount point or a device node, so the path is resolved
   to its device first. [df] answers that for any path on the volume. *)
let device_of_path path =
  match run (Printf.sprintf "/bin/df -P %s" (Filename.quote path)) with
    | _header :: line :: _ -> (
        match String.split_on_char ' ' line with
          | device :: _ when device <> "" -> Some device
          | _ -> None)
    | _ -> None

(* Any failure — missing binary, a path off any volume, a device it will not
   describe — is "no opinion", never a guess. *)
let describe path =
  match device_of_path path with
    | None -> []
    | Some device ->
        run
          (Printf.sprintf "/usr/sbin/diskutil info %s" (Filename.quote device))

let lookup lines name = List.find_map (field name) lines

let max_concurrency path =
  let lines = describe path in
  match lines with
    | [] -> None
    | _ -> (
        let solid_state = lookup lines "Solid State" in
        let protocol = lookup lines "Protocol" in
        let external_ = lookup lines "Device Location" = Some "External" in
        match (solid_state, protocol) with
          (* Spinning behind a bus that serialises commands: the case that
             collapses under concurrency. *)
          | Some "No", Some ("USB" | "FireWire") -> Some 4
          (* Spinning, but on a bus that can keep several commands in flight. *)
          | Some "No", _ -> Some 8
          (* Solid state, but the bus is still in the way and a cheap enclosure
             may serialise regardless. *)
          | Some "Yes", Some "USB" -> Some 16
          | Some "Yes", _ -> Some 64
          (* Answered, but not about this. An external volume of unknown kind is
             the likelier one to be slow. *)
          | _ -> if external_ then Some 8 else None)

external clonefile : src:string -> dst:string -> bool = "tsync_clonefile"

(* [clonefile] creates the destination itself, so unlike the Linux side there is
   nothing to open before it and nothing to unlink when it fails. *)
let clone ~src =
  let dst = Filename.temp_path src in
  if clonefile ~src ~dst then Some (Io_lwt.Fs.open_and_unlink dst) else None
