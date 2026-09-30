(lang dune 3.17)
(name tsync)
(license MIT)
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
 (depopts fuse3)
 (conflicts
  (fuse3 (< 3.10.0.1))))
