.PHONY: build test deploy configure install-deps install-opam install-system install uninstall e2e conformance stress live-rsync install-completion

SHAREDIR ?= $(HOME)/.local/share

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
	$(MAKE) install-completion

# The scripts are cmdliner's own, and the tool answers its protocol already, so
# there is nothing here to keep in step with the commands.
install-completion:
	cmdliner install generic-completion $(SHAREDIR)
	cmdliner install tool-completion tsync $(SHAREDIR)
	@echo "completion installed under $(SHAREDIR); it is read once that is on"
	@echo "  zsh:  fpath   (or XDG_DATA_DIRS)"
	@echo "  bash: XDG_DATA_DIRS, with bash-completion loaded"

# The daemon, and nothing else. The tray and Dolphin's context-menu action
# install system-wide, pull Qt, KDE Frameworks and libdbus, and are what
# tsync-tray and tsync-dolphin exist to deliver -- building them from here would
# put files under /usr that no package owns.
install-system:
	mkdir -p ~/.local/bin
	ln -sf "$$(opam var bin)/tsync" ~/.local/bin/tsync
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
	@echo
	@echo "Installed the tsync daemon only."
	@echo "The system tray and Dolphin's Copy Share Link are not installed from"
	@echo "here: they ship as the tsync-tray and tsync-dolphin packages."

install: install-opam install-system

# Every step tolerates already being undone, so a partial install still cleans
# up. Lingering is left enabled: it is a user-wide setting other services may
# depend on, and turning it off is one command if you want it gone.
uninstall:
	-systemctl --user disable --now tsync
	rm -f ~/.config/systemd/user/tsync.service
	-systemctl --user daemon-reload
	rm -f ~/.local/bin/tsync
	# Under /usr and owned by tsync-tray and tsync-dolphin, so removing them is
	# the package manager's to do. What follows is an earlier install-system's
	# leavings in this user's own directories, which nothing else claims.
	rm -f ~/.local/bin/tsync-tray
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

# The copy command against a real domain, which is where its one claim -- that a
# copy inside a domain moves no bytes -- can actually be read off the wire.
# TSYNC_LIVE_CONFIG names a config JSON holding one writable domain; without it
# the suite exits 2 rather than reporting a pass it did not earn.
live-rsync:
	cd .. && dune build bin/tsync.exe tests/live/rsync/live_rsync.exe && ./_build/default/tests/live/rsync/live_rsync.exe
