(lang dune 3.23)
(name tsync)
(license MIT)

; The opam files under opam/ are written by hand, not generated from these
; stanzas: tsync depends on one of two TLS backend packages and dune has no
; syntax for an opam alternative. What is left here is only what dune itself
; reads — the package names it builds with `dune build -p`.

(package
 (name tsync))

; The libraries, public so a frontend in a package of its own can depend on
; them. The frontend and backend aggregators deliberately stay in tsync: their
; (select ...) has to be re-asked when the binary is built, which is what makes
; tsync-s3, tsync-fuse and tsync-android take effect on a rebuild.

(package
 (name tsync-libs))

(package
 (name tsync-tls)
 (version 1)
 (allow_empty))

(package
 (name tsync-ssl)
 (version 1)
 (allow_empty))

(package
 (name tsync-s3)
 (version 1)
 (allow_empty))

(package
 (name tsync-fuse)
 (version 1)
 (allow_empty))

(package
 (name tsync-android)
 (version 1)
 (allow_empty))

; Its own package rather than a tsync subcommand: libdbus is a header
; dependency at build time, and confining it here keeps `dune build -p tsync'
; working on a machine that has none. The binary links the IPC client and the
; config parser and nothing else, so it is small rather than a second copy of
; the daemon.

(package
 (name tsync-tray)
 ; Its stanzas are Linux-only, so on macOS the package has none at all and dune
 ; refuses to build a tree containing it.
 (allow_empty))
