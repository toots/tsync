(* vault §3.1: the emergency kit, one self-contained HTML page for the browser
   to print. *)

let escape s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '<' -> Buffer.add_string b "&lt;"
      | '>' -> Buffer.add_string b "&gt;"
      | '&' -> Buffer.add_string b "&amp;"
      | '"' -> Buffer.add_string b "&quot;"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let qr spelling =
  match Qrc.encode ~ec_level:`M spelling with
    | Some m -> Qrc.Matrix.to_svg ~w_mm:45 m
    | None -> Tsync_core.Fail.invalid "the secret key does not fit a QR code"

let page ~domain ~date ~secret_key =
  let domain = escape domain and secret_key_text = escape secret_key in
  Printf.sprintf
    {|<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>tsync emergency kit: %s</title>
<style>
body { font: 14px/1.5 system-ui, sans-serif; color: #111; background: #fff; max-width: 720px; margin: 32px auto; padding: 0 16px; }
h1 { font-size: 22px; margin-bottom: 4px; }
h2 { font-size: 16px; margin: 24px 0 8px; }
.key { font: 20px/1.4 ui-monospace, monospace; letter-spacing: 0.04em; padding: 10px 14px; border: 1px solid #888; border-radius: 6px; display: inline-block; }
.qr svg { width: 45mm; height: 45mm; margin-top: 12px; }
.box { height: 52px; border: 1px solid #888; border-radius: 6px; }
.warn { margin-top: 32px; padding: 12px 14px; background: #fff4e5; border-radius: 6px; }
@media print { .warn { display: none; } body { margin: 0 auto; } }
</style>
<h1>tsync emergency kit</h1>
<p>The vault of the domain <b>%s</b>, as of %s.</p>
<h2>Secret key</h2>
<div class="key">%s</div>
<div class="qr">%s</div>
<h2>Passphrase</h2>
<p>Write it here by hand. It is not in this file, and tsync never shows it.</p>
<div class="box"></div>
<h2>On a new machine</h2>
<ol>
<li>Install tsync, and give it the domain <b>%s</b>.</li>
<li>Run <code>tsync vault unlock</code>.</li>
<li>Type the passphrase, then the secret key above.</li>
</ol>
<p class="warn"><b>This file holds the secret key in plain text.</b> Print it, keep the paper with your important documents, and delete the file.</p>
</html>
|}
    domain domain date secret_key_text (qr secret_key) domain

(* vault §3.1: created with mode 0600 and never replaced. *)
let write ~path ~domain ~secret_key =
  let tm = Unix.localtime (Unix.time ()) in
  let date =
    Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
      tm.tm_mday
  in
  let body = page ~domain ~date ~secret_key in
  let fd =
    try Unix.openfile path [O_WRONLY; O_CREAT; O_EXCL; O_CLOEXEC] 0o600
    with Unix.Unix_error (EEXIST, _, _) ->
      Tsync_core.Fail.invalid "%s exists: a kit never replaces a file" path
  in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> ignore (Unix.write_substring fd body 0 (String.length body)))
