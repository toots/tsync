(* What an export makes of one file, from the record it kept and what is at the
   destination. A record is believed only when it is this content going to this
   place, and only as far as its last whole line. *)

let id =
  {
    Export.Record.h1 = "aaaaaaaaaaaaaaaa";
    h2 = "bbbbbbbbbbbbbbbb";
    size = 40L;
    chunk_size = 8;
    dst = "/mnt/big disk/Camera 1/P101.MOV";
  }

let count = 5
let header = Export.Record.header id
let claims l = String.concat "" (List.map Export.Record.claim l)

let claimed bits =
  String.concat ""
    (List.init (Bytes.length bits) (fun i ->
         if Export.Record.is_claimed bits i then "#" else "."))

let decide label ~record ~dst =
  let verdict =
    match Export.decide ~count ~identity:id ~mtime:1000. ~record ~dst with
      | `Fresh -> "start over"
      | `Already_there -> "already there"
      | `Resume bits ->
          Printf.sprintf "resume %s (%d of %d)" (claimed bits)
            (Export.Record.claimed_count bits)
            count
  in
  Printf.printf "  %-46s %s\n" label verdict

let whole = Some { Export.size = 40L; mtime = 1000. }
let sized = Some { Export.size = 40L; mtime = 5. }

let () =
  print_string "header\n  ";
  print_string header;

  print_endline "a record beside a file of the right length";
  decide "nothing claimed yet" ~record:(Some header) ~dst:sized;
  decide "chunks out of order"
    ~record:(Some (header ^ claims [3; 0; 1]))
    ~dst:sized;
  decide "every chunk, the run having died at the end"
    ~record:(Some (header ^ claims [0; 1; 2; 3; 4]))
    ~dst:sized;
  decide "a claim cut short by a crash"
    ~record:(Some (header ^ claims [0; 1] ^ "3"))
    ~dst:sized;
  decide "a line that is no index ends the record"
    ~record:(Some (header ^ claims [0] ^ "x\n" ^ claims [2]))
    ~dst:sized;
  decide "as does one out of range"
    ~record:(Some (header ^ claims [0] ^ "5\n" ^ claims [2]))
    ~dst:sized;
  decide "and one not spelled as it would be written"
    ~record:(Some (header ^ "01\n" ^ claims [2]))
    ~dst:sized;

  print_endline "a record that is not to be believed";
  decide "the file is gone" ~record:(Some (header ^ claims [0])) ~dst:None;
  decide "the file is another length"
    ~record:(Some (header ^ claims [0]))
    ~dst:(Some { Export.size = 39L; mtime = 5. });
  decide "other content"
    ~record:
      (Some
         (Export.Record.header { id with Export.Record.h1 = "cccccccccccccccc" }
         ^ claims [0]))
    ~dst:sized;
  decide "another destination"
    ~record:
      (Some
         (Export.Record.header { id with Export.Record.dst = "/elsewhere" }
         ^ claims [0]))
    ~dst:sized;
  decide "cut off inside its header"
    ~record:(Some (String.sub header 0 20))
    ~dst:sized;

  print_endline "no record";
  decide "size and time are the manifest's" ~record:None ~dst:whole;
  decide "the time a coarse filesystem kept" ~record:None
    ~dst:(Some { Export.size = 40L; mtime = 1001.5 });
  decide "right size, another time" ~record:None ~dst:sized;
  decide "nothing there" ~record:None ~dst:None;

  print_endline "where a file lands under /out";
  List.iter
    (fun (asked, rel) ->
      Printf.printf "  asked %-12S holds %-22S -> %s\n" asked rel
        (Export.landing ~dst:"/out" ~asked ~rel))
    [
      ("", "a.txt");
      ("", "docs/deep/b.txt");
      ("a.txt", "a.txt");
      ("docs/deep/b.txt", "docs/deep/b.txt");
      ("docs", "docs/deep/b.txt");
      ("docs/deep", "docs/deep/b.txt");
    ]
