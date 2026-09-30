open Tsync_core
open Tsync_store
module B = Uplink.Budget

let p fmt = Printf.printf (fmt ^^ "\n%!")

let () =
  p "== budget (uplink-governor §4.2), 1000 B/s: burst 2000, window 30000";
  let b = B.create ~rate:1000. ~now:0. in
  p "admits 1500 at 0: %b" (B.admits b ~now:0. 1500);
  B.take b ~now:0. 1500;
  p "admits 1000 at 0: %b, waits %.2fs" (B.admits b ~now:0. 1000)
    (B.wait_for b ~now:0. 1000);
  p "admits 1000 at 0.5: %b" (B.admits b ~now:0.5 1000);
  B.release b 1500;
  let big = B.create ~rate:1000. ~now:0. in
  p "a body over the bucket alone: %b" (B.admits big ~now:0. 50_000);
  B.take big ~now:0. 50_000;
  p "then the window blocks: waits %s"
    (let w = B.wait_for big ~now:100. 100 in
     if w = infinity then "until a completion" else string_of_float w);
  B.release big 50_000;
  p "after its completion, debt paid by 100s: %b" (B.admits big ~now:100. 100);
  p "== gate at 1 MiB/s";
  Rt.run_sync (fun () ->
      let link =
        Uplink.link "test" ~enabled:true ~max_rate:(Some (1024 * 1024))
      in
      let t0 = Rt.now () in
      List.iter
        (fun _ ->
          let tk = Uplink.acquire link (512 * 1024) in
          Uplink.completed link tk)
        (List.init 8 Fun.id);
      let took = Rt.now () -. t0 in
      p "4 MiB in 512 KiB bodies: %s"
        (if took > 1.6 && took < 2.8 then "about 2 s (the burst is 2 s of rate)"
         else Printf.sprintf "%.2fs" took);
      p "a best-effort body beyond the budget: %s"
        (match Uplink.try_acquire link (8 * 1024 * 1024) with
          | Some _ -> "admitted"
          | None -> "refused");
      p "an unlimited link admits at once: %b"
        (let u = Uplink.link "open" ~enabled:true ~max_rate:None in
         Uplink.try_acquire u max_int <> None))
