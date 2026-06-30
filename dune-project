(lang dune 3.23)
(name tsync)
(generate_opam_files true)
(package
 (name tsync)
 (synopsis "S3-backed FUSE filesystem sync tool")
 (maintainers "Romain Beauxis <toots@rastageeks.org>")
 (authors "Romain Beauxis <toots@rastageeks.org>")
 (homepage "https://github.com/toots/tsync")
 (bug_reports "https://github.com/toots/tsync/issues")
 (license MIT)
 (depends
  (ocaml (>= 5.5.0))
  dune
  yojson
  fuse3
  aws-s3-lwt
  lwt
  lwt_ppx
  lwt_ssl
  syslog
  cmdliner))
