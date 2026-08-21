.PHONY: build test deploy configure install-deps install-opam install-system install uninstall e2e conformance stress

build:
	dune build

test:
	dune test

deploy: build
	./deploy.sh

configure:
	./configure.sh

install-deps:
	opam pin add -ny fuse3 git+https://github.com/toots/ocamlfuse.git
	opam pin add -ny git+https://github.com/toots/aws-s3.git#tsync
	opam pin add -ny git+https://github.com/toots/ocaml-cohttp.git#bigstring-body
	opam pin add -ny git+https://github.com/janestreet/memtrace.git#master
	cd .. && opam pin -ny .
	opam install --deps-only tsync tsync-s3 tsync-ssl

install-opam:
	cd .. && opam pin -ny .
	opam install tsync

install-system:
	mkdir -p ~/.local/bin
	ln -sf "$$(opam var bin)/tsync" ~/.local/bin/tsync
	ln -sf "$$(opam var bin)/tsync-tray" ~/.local/bin/tsync-tray
	# Started by the desktop, not by systemd: see the comment in the .desktop.
	mkdir -p ~/.config/autostart
	sed 's|@BIN@|$(HOME)/.local/bin/tsync-tray|' tsync-tray.desktop.in \
	  > ~/.config/autostart/tsync-tray.desktop
	# Every theme inherits hicolor, so this is where an icon is found whatever
	# the desktop. The four tray states go under symbolic/ and keep the suffix
	# in their name: GTK only recolours an icon to the panel foreground when
	# both are true, and the SVGs carry the stylesheet KDE recolours by.
	mkdir -p ~/.local/share/icons/hicolor/scalable/apps
	mkdir -p ~/.local/share/icons/hicolor/symbolic/apps
	cp ../assets/tsync-app.svg ~/.local/share/icons/hicolor/scalable/apps/tsync.svg
	cp ../assets/tray/tsync-*-symbolic.svg ~/.local/share/icons/hicolor/symbolic/apps/
	# Advisory: GTK scans the directory when the cache is missing or stale, so a
	# desktop without the tool installed still finds the icons.
	-gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor 2>/dev/null
	# Not advisory for Plasma. It snapshots which of hicolor's directories
	# exist, and the two above are ones a fresh machine has never had, so a
	# panel already running resolves nothing under them until told to look
	# again -- an install whose icons only appear after the next login.
	-gdbus emit --session --object-path /KIconLoader \
	  --signal org.kde.KIconLoader.iconChanged 0 2>/dev/null
	mkdir -p ~/.config/systemd/user
	cp tsync.service ~/.config/systemd/user/
	systemctl --user daemon-reload
	systemctl --user enable tsync
	systemctl --user restart tsync
	# Without lingering the user manager only runs while a session is open, so a
	# headless box comes back from reboot with nothing started. Needs root, so
	# skip the prompt when it is already set.
	loginctl show-user "$$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes' \
	  || sudo loginctl enable-linger "$$USER"

install: install-opam install-system

# Every step tolerates already being undone, so a partial install still cleans
# up. Lingering is left enabled: it is a user-wide setting other services may
# depend on, and turning it off is one command if you want it gone.
uninstall:
	-systemctl --user disable --now tsync
	rm -f ~/.config/systemd/user/tsync.service
	-systemctl --user daemon-reload
	rm -f ~/.local/bin/tsync ~/.local/bin/tsync-tray
	rm -f ~/.config/autostart/tsync-tray.desktop
	rm -f ~/.local/share/icons/hicolor/scalable/apps/tsync.svg
	rm -f ~/.local/share/icons/hicolor/symbolic/apps/tsync-*-symbolic.svg
	-gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor 2>/dev/null
	-opam remove -y tsync tsync-tls tsync-ssl tsync-s3 tsync-fuse tsync-tray

# End-to-end check against a real FUSE mount. Stages everything it needs — a
# store, a mount, a second client — under a scratch directory and takes it all
# down again, touching no shared config and no service. Needs fuse3 and
# permission to mount. Not part of `dune test`: it mounts a filesystem.
e2e:
	cd .. && dune build bin/tsync.exe tests/e2e/linux/e2e_linux.exe && ./_build/default/tests/e2e/linux/e2e_linux.exe

# Talks to real object stores, so it is driven from here rather than from
# `dune runtest`: it needs credentials, and it exits 2 when it was given none
# rather than reporting a pass it did not earn.
conformance:
	cd .. && dune build tests/conformance/conformance.exe && ./_build/default/tests/conformance/conformance.exe

# Concurrent load over two real mounts, judged against an oracle. Prints the
# seed it used; TSYNC_STRESS_SEED replays a run, TSYNC_STRESS_OPS sizes it, and
# TSYNC_STRESS_KEEP leaves the scratch directory behind (a failing run keeps it
# either way).
stress:
	cd .. && dune build bin/tsync.exe tests/e2e/stress/stress.exe && ./_build/default/tests/e2e/stress/stress.exe
