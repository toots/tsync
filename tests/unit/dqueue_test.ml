open Tsync_core

let p fmt = Printf.printf fmt

(* A job is "<key>:<attempts>" on disk; its name decides how it fails. *)
let kind =
  {
    Dqueue.decode =
      (fun b ->
        match String.split_on_char ':' b with
          | [k; n] -> Option.map (fun n -> (k, n)) (int_of_string_opt n)
          | _ -> None);
    encode = (fun (k, n) -> Printf.sprintf "%s:%d" k n);
    key = (fun (k, _) -> Some (List.hd (String.split_on_char '.' k)));
    note = (fun (k, n) _ -> (k, n + 1));
    accepts = (fun _ -> true);
  }

let log = ref []
let record s = log := s :: !log

let run _id (k, n) ~cancel =
  record (Printf.sprintf "%s#%d" k n);
  if String.starts_with ~prefix:"flaky" k && n < 2 then Fail.raise_ Link "flaky";
  if String.starts_with ~prefix:"refused" k then Fail.raise_ Refused "refused";
  if String.starts_with ~prefix:"slow" k then (
    Rt.sleep 0.2;
    if Atomic.get cancel then raise Rt.Cancelled)

let dir =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-dq-%d" (Unix.getpid ()))

let settle q =
  Dqueue.settle ~timeout:5. q;
  Rt.sleep 0.05

let () =
  Fs.rm_rf dir;
  Rt.run_sync (fun () ->
      p
        "== ordered: head retry keeps order, a refusal parks and later records \
         pass\n";
      let r = Dqueue.Records.open_ (Filename.concat dir "ordered") in
      let q = Dqueue.create ~name:"ordered" ~ordered:true kind r in
      Dqueue.start q run;
      List.iter
        (fun j -> ignore (Dqueue.post q (j, 0)))
        ["a"; "flaky"; "refused"; "b"];
      let rec wait n =
        if n > 0 && Dqueue.pending q > 0 then (
          Rt.sleep 0.1;
          wait (n - 1))
      in
      wait 50;
      p "ran: %s\n" (String.concat " " (List.rev !log));
      p "parked: %s; records on disk: %d\n"
        (String.concat ","
           (List.map
              (fun (_, (n : Dqueue.failure_note)) -> Fail.kind_name n.last.kind)
              (Dqueue.parked q)))
        (List.length (Dqueue.Records.list r));
      log := [];
      p
        "\n\
         == keyed: a new post replaces the pending job and cancels the running \
         one\n";
      let r = Dqueue.Records.open_ (Filename.concat dir "keyed") in
      let q = Dqueue.create ~workers:4 ~name:"keyed" ~ordered:false kind r in
      Dqueue.start q run;
      ignore (Dqueue.post q ("slow.1", 0));
      Rt.sleep 0.05;
      ignore (Dqueue.post q ("slow.2", 0));
      ignore (Dqueue.post q ("slow.3", 0));
      ignore (Dqueue.post q ("other", 0));
      let rec wait n =
        if n > 0 && not (Dqueue.idle q) then (
          Rt.sleep 0.1;
          wait (n - 1))
      in
      wait 50;
      p "ran: %s\n" (String.concat " " (List.sort compare (List.rev !log)));
      p "records on disk: %d\n" (List.length (Dqueue.Records.list r));
      log := [];
      p
        "\n\
         == restart: records persist, undecodable ones are set aside, held \
         submissions wait\n";
      let rdir = Filename.concat dir "restart" in
      let r = Dqueue.Records.open_ rdir in
      ignore (Dqueue.Records.create r "x:0");
      Fs.write_file_for_test
        (Filename.concat rdir "00000000000000000001-00000000-1")
        "garbage";
      let held = Dqueue.Records.create r "held:0" in
      let fd = Dqueue.Records.hold r held in
      let q = Dqueue.create ~name:"restart" ~ordered:true kind r in
      Dqueue.start q run;
      settle q;
      p "ran: %s; set aside: %s\n"
        (String.concat " " (List.rev !log))
        (String.concat "," (Dqueue.Records.set_aside_records r));
      Fs.close fd;
      Dqueue.rescan q;
      settle q;
      p "after release: %s\n" (String.concat " " (List.rev !log));
      p "\n== pause holds everything\n";
      log := [];
      Dqueue.pause q;
      ignore (Dqueue.post q ("p", 0));
      Rt.sleep 0.2;
      p "while paused: [%s], pending %d\n" (String.concat " " !log)
        (Dqueue.pending q);
      Dqueue.resume q;
      settle q;
      p "after resume: %s\n" (String.concat " " (List.rev !log)));
  Fs.rm_rf dir
