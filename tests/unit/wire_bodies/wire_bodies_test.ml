(* Framing a batch of bodies.

   The keys are not on the wire — the order is the contract — so a decoder has
   only the length prefixes to tell a whole answer from a truncated one. An
   answer that decoded short would read as a run of absent keys, and a caller
   told a key is absent writes a mirror missing that file. *)

open Check
module Wire = Http_proxy.Wire

let body s = Some (Chunk.of_string s)
let rendered = List.map (fun (k, b) -> (k, Option.map Chunk.to_string b))

let raises what f =
  match f () with
    | _ -> check what false
    | exception Failure _ -> check what true

let () =
  case "a batch survives the round trip";
  let answered = [("a", body "alpha"); ("b", None); ("c", body "")] in
  let keys = List.map fst answered in
  let framed = Wire.bodies_to_string answered in
  check "keys, order and bodies come back"
    (rendered (Wire.bodies_of_string ~keys framed) = rendered answered);
  check "an empty body is not an absent one"
    (match Wire.bodies_of_string ~keys framed with
      | [_; (_, None); (_, Some e)] -> Chunk.length e = 0
      | _ -> false);

  case "a mangled answer is refused, not misread";
  raises "a truncated body"
    (fun () ->
      Wire.bodies_of_string ~keys
        (String.sub framed 0 (String.length framed - 1)));
  raises "fewer entries than keys"
    (fun () -> Wire.bodies_of_string ~keys:(keys @ ["d"]) framed);
  raises "more entries than keys"
    (fun () -> Wire.bodies_of_string ~keys:["a"] framed);
  raises "a length prefix cut in half"
    (fun () -> Wire.bodies_of_string ~keys:["a"] "\x00\x00");

  case "a body larger than one socket read";
  let big = String.init 200_000 (fun i -> Char.chr (i * 31 land 0xff)) in
  let framed = Wire.bodies_to_string [("big", body big)] in
  check "comes back byte for byte"
    (rendered (Wire.bodies_of_string ~keys:["big"] framed)
    = [("big", Some big)]);
  report ~expected:7 ()
