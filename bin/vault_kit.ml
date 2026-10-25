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

(* vault §8.3: the backup key's kit has no passphrase box and restores rather
   than enrolls. *)
let page ~domain ~date kit =
  let title, heading, key, rest =
    match kit with
      | `Emergency secret_key ->
          ( "emergency kit",
            "Secret key",
            secret_key,
            Printf.sprintf
              {|<h2>Passphrase</h2>
<p>Write it here by hand. It is not in this file, and tsync never shows it.</p>
<div class="box"></div>
<h2>On a new machine</h2>
<ol>
<li>Install tsync, and give it the domain <b>%s</b>.</li>
<li>Run <code>tsync vault unlock</code>.</li>
<li>Type the passphrase, then the secret key above.</li>
</ol>
<p class="warn"><b>This file holds the secret key in plain text.</b> Print it, keep the paper with your important documents, and delete the file.</p>|}
              (escape domain) )
      | `Backup (seed, id) ->
          ( "backup kit",
            "Backup key " ^ escape id,
            seed,
            Printf.sprintf
              {|<p>It opens the vault's scheduled backups, and nothing else. No machine keeps it.</p>
<h2>To restore a backup</h2>
<ol>
<li>Install tsync, give it the domain <b>%s</b>, and run <code>tsync vault init</code> if the domain has no vault.</li>
<li>Run <code>tsync vault import --backup-key FILE</code>.</li>
<li>Type the backup key above.</li>
</ol>
<p class="warn"><b>This file holds the backup key in plain text.</b> Print it, keep the paper apart from your computers, and delete the file.</p>|}
              (escape domain) )
  in
  let domain = escape domain and key_text = escape key in
  Printf.sprintf
    {|<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>tsync %s: %s</title>
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
<h1>tsync %s</h1>
<p>The vault of the domain <b>%s</b>, as of %s.</p>
<h2>%s</h2>
<div class="key">%s</div>
<div class="qr">%s</div>
%s
</html>
|}
    title domain title domain date heading key_text (qr key) rest

(* vault §3.1: created with mode 0600 and never replaced. *)
let write ~path ~domain kit =
  let tm = Unix.localtime (Unix.time ()) in
  let date =
    Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
      tm.tm_mday
  in
  try Tsync_core.Fs.create_new path (page ~domain ~date kit)
  with Tsync_core.Fail.E { kind = Exists; _ } ->
    Tsync_core.Fail.invalid "%s exists: a kit never replaces a file" path
