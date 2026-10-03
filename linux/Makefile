.PHONY: build test install-opam install-completion install-system install uninstall

SHAREDIR ?= $(HOME)/.local/share

build:
	cd .. && dune build

test:
	cd .. && dune build @runtest

# With FUSE and both TLS implementations, as the packages ship.
install-opam:
	cd .. && opam pin -ny .
	opam install tsync tsync-fuse tsync-tls tsync-ssl
	$(MAKE) install-completion

# The scripts are cmdliner's own, and the tool answers its protocol already, so
# nothing here keeps in step with the commands.
install-completion:
	cmdliner install generic-completion $(SHAREDIR)
	cmdliner install tool-completion tsync $(SHAREDIR)
	@echo "completion installed under $(SHAREDIR); it is read once that is on"
	@echo "  zsh:  fpath   (or XDG_DATA_DIRS)"
	@echo "  bash: XDG_DATA_DIRS, with bash-completion loaded"

# fuse B5: the user unit, with lingering so a headless machine starts it at
# boot without a session.
install-system:
	mkdir -p ~/.local/bin
	ln -sf "$$(opam var bin)/tsync" ~/.local/bin/tsync
	mkdir -p ~/.config/systemd/user
	cp tsync.service ~/.config/systemd/user/
	systemctl --user daemon-reload
	systemctl --user enable tsync
	systemctl --user restart tsync
	loginctl show-user "$$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes' \
	  || sudo loginctl enable-linger "$$USER"

install: install-opam install-system

# Every step tolerates already being undone. Lingering stays enabled: it is a
# user-wide setting other services may rely on.
uninstall:
	-systemctl --user disable --now tsync
	rm -f ~/.config/systemd/user/tsync.service
	-systemctl --user daemon-reload
	rm -f ~/.local/bin/tsync
	-opam remove -y tsync tsync-tls tsync-ssl tsync-fuse
