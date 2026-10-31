open Tsync_owner

let rows handler ref_ =
  let rec pages after acc =
    let (page : Protocol.page) =
      Handler.call handler
        (List_dir { dir = Ref ref_; after; limit = None; pull = `Never })
    in
    let acc = List.rev_append page.items acc in
    match page.next with Some n -> pages (Some n) acc | None -> List.rev acc
  in
  pages None []
