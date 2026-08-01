(* macOS: nothing publishes a queue depth the way sysfs does, and reaching the
   equivalent means IOKit, which means C stubs. [diskutil] already asks IOKit and
   prints the answer, so this reads that instead — one subprocess, once per
   store, at start-up.

   What comes back is a category rather than a number, so the figures below are a
   judgement about classes of device rather than a measurement of this one. The
   distinction that matters is the same one that matters on Linux: a spinning
   disk behind USB takes very little at once, and everything else takes plenty.
   Being wrong high here costs what it costs everywhere — requests queueing at
   the device instead of in front of it — so the uncertain cases lean low. *)

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

(* [diskutil] will not take an arbitrary path — only a mount point or a device
   node — so the path is resolved to its device first. [df] answers that for any
   path on the volume, which a store root generally is. *)
let device_of_path path =
  match run (Printf.sprintf "/bin/df -P %s" (Filename.quote path)) with
    | _header :: line :: _ -> (
        match String.split_on_char ' ' line with
          | device :: _ when device <> "" -> Some device
          | _ -> None)
    | _ -> None

(* Failure of any kind — missing binary, a path off any volume, a device it will
   not describe — is "no opinion", never a guess. *)
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
          (* Spinning, and reached over a bus that serialises commands: the case
             that collapses under concurrency. *)
          | Some "No", Some ("USB" | "FireWire") -> Some 4
          (* Spinning, but on a bus that can keep several commands in flight. *)
          | Some "No", _ -> Some 8
          (* Solid state behind USB still has the bus in the way, and a cheap
             enclosure may be serialising even so. *)
          | Some "Yes", Some "USB" -> Some 16
          | Some "Yes", _ -> Some 64
          (* It answered, but not about this: an external volume of unknown
             kind is the likelier one to be slow. *)
          | _ -> if external_ then Some 8 else None)
