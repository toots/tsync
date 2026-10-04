(lang dune 3.17)
(name tsync)
(license MIT)
(implicit_transitive_deps false)

; The opam files are written by hand, not generated from these stanzas: tsync
; depends on one of two TLS packages and dune has no syntax for an opam
; alternative. What is left here is what dune itself reads: the packages it
; builds with `dune build -p`.

(package
 (name tsync))

; tsync-tls, tsync-ssl and tsync-fuse install nothing of their own: each brings
; a library that tsync takes as a depopt, so installing one rebuilds tsync,
; whose optional library and the catalog's select then link it in.

(package
 (name tsync-tls)
 (allow_empty))

(package
 (name tsync-ssl)
 (allow_empty))

(package
 (name tsync-fuse)
 (allow_empty))

; The tray is its own package so that the bus library stays off a headless
; install (frontends/linux-desktop.md §5.1).

(package
 (name tsync-tray)
 (allow_empty))

; conf-dbus builds nothing: it stands for the system's libdbus.

(package
 (name conf-dbus)
 (allow_empty))

; tsync-android installs nothing either: its dependencies are the cross switch
; the Android app's core library is built in.

(package
 (name tsync-android)
 (allow_empty))
