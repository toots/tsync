(* Fs.drop_mapped_pages: a used mapping's pages leave the resident set, its
   content still reads from the file, and a malloc'd buffer is left alone. *)

open Tsync_core

let p fmt = Printf.printf fmt

let resident () =
  In_channel.with_open_text "/proc/self/status" In_channel.input_lines
  |> List.find_map (fun l ->
      match String.split_on_char ':' l with
        | ["VmRSS"; v] ->
            Scanf.sscanf (String.trim v) "%d kB" (fun kb -> Some (kb / 1024))
        | _ -> None)
  |> Option.value ~default:(-1)

let touch b =
  let sum = ref 0 in
  for i = 0 to (Bigstring.length b / 4096) - 1 do
    sum := !sum + Char.code (Bigarray.Array1.get b (i * 4096))
  done;
  !sum

let () =
  let path = Filename.temp_file "tsync-mapped" ".bin" in
  let size = 64 * 1024 * 1024 in
  Out_channel.with_open_bin path (fun oc ->
      output_string oc (String.init size (fun i -> Char.chr (i mod 251))));
  let before = resident () in
  let b = Fs.map_file path in
  let sum = touch b in
  let mapped = resident () in
  Fs.drop_mapped_pages b;
  let dropped = resident () in
  p "a 64 MiB mapping, read: resident grew by at least 48 MiB: %b\n"
    (mapped - before >= 48);
  p "after the drop: shrank by at least 48 MiB: %b\n" (mapped - dropped >= 48);
  p "content reads the same after the drop: %b\n" (touch b = sum);
  let m = Bigstring.of_string "not a mapping" in
  Fs.drop_mapped_pages m;
  p "a malloc'd buffer is untouched: %b\n"
    (Bigstring.to_string m = "not a mapping");
  Sys.remove path
