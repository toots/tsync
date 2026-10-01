(lang dune 3.17)
(name tsync)
(license MIT)
(maintainers "Romain Beauxis <toots@rastageeks.org>")
(authors "Romain Beauxis <toots@rastageeks.org>")
(source (github toots/tsync))
(implicit_transitive_deps false)
(generate_opam_files true)

(package
 (name tsync)
 (synopsis "Synchronise folders through object stores")
 (depends
  (ocaml (>= 5.5))
  dune
  base64
  ca-certs
  cmdliner
  digestif
  domain-name
  eqaf
  mem_usage
  mirage-crypto-pk
  mirage-crypto-rng
  ppx_deriving_yojson
  ptime
  re
  ssl
  tls
  x509
  yojson)
 (depopts tsync-fuse)
 (conflicts
  (fuse3 (< 3.10.0.1))))

; Installing it is what enables FUSE: it brings the binding, and as a depopt
; of tsync it rebuilds tsync, whose optional FUSE library and the catalog's
; select then link it in. It installs nothing of its own.

(package
 (name tsync-fuse)
 (synopsis "FUSE frontend support for tsync")
 (allow_empty)
 (depends
  (fuse3 (>= 3.10.0.1))))
