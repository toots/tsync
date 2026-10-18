let magic = "tsv1"
let key_id_size = 8
let header_size = String.length magic + key_id_size + Crypto.nonce_size
let min_size = header_size + Crypto.tag_size

let unhex s =
  String.init
    (String.length s / 2)
    (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (2 * i) 2)))

let ad ~extension ~key_id = "tsync-vault/" ^ extension ^ "/" ^ key_id

let seal ~key ~key_id ~extension plaintext =
  let nonce = Tsync_core.Ids.urandom Crypto.nonce_size in
  String.concat ""
    [
      magic;
      unhex key_id;
      nonce;
      Crypto.seal ~key ~nonce ~ad:(ad ~extension ~key_id) plaintext;
    ]

let open_ ~key ~key_id ~extension body =
  if String.length body < min_size || String.sub body 0 4 <> magic then
    Error `Corrupt
  else (
    let body_key_id = Tsync_core.Ids.hex (String.sub body 4 key_id_size) in
    if body_key_id <> key_id then Error (`Other_key body_key_id)
    else (
      let nonce = String.sub body (4 + key_id_size) Crypto.nonce_size in
      let sealed =
        String.sub body header_size (String.length body - header_size)
      in
      match Crypto.open_ ~key ~nonce ~ad:(ad ~extension ~key_id) sealed with
        | Some plaintext -> Ok plaintext
        | None -> Error `Corrupt))
