#!/usr/bin/env bash
#
# Provision the key the apt and dnf repositories are signed with.
#
# apt refuses an unsigned repository outright, so publishing needs a key CI
# holds. This makes one, keeps the secret half out of the repository, and hands
# it to CI as one secret.
#
# Idempotent: an existing key is reused rather than replaced -- replacing it
# stops every machine that already trusts the old one from updating until it
# imports the new one by hand.
#
#   bash scripts/setup_repo_signing.sh            # do it
#   bash scripts/setup_repo_signing.sh --help     # this
#
set -euo pipefail

REPO="${REPO:-toots/tsync}"
KEYFILE="${KEYFILE:-$HOME/.config/tsync/repo-signing.asc}"
UID_LINE="${UID_LINE:-tsync package repository <toots@rastageeks.org>}"

case "${1:-}" in
  --help | -h) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

if [ -f "$KEYFILE" ]; then
  echo "using the key at $KEYFILE"
else
  # Its own keyring, so a key that only CI ever uses does not end up in the
  # keyring you sign your own things with.
  home=$(mktemp -d)
  chmod 700 "$home"
  GNUPGHOME=$home gpg --batch --quiet --passphrase '' \
    --quick-generate-key "$UID_LINE" rsa4096 sign never
  mkdir -p "$(dirname "$KEYFILE")"
  (umask 077 && GNUPGHOME=$home gpg --batch --armor --export-secret-keys > "$KEYFILE")
  rm -rf "$home"
  echo "made $KEYFILE -- back it up: losing it means every machine re-adds the repo"
fi

gh secret set REPO_SIGNING_KEY -R "$REPO" < "$KEYFILE"
echo "secret set on $REPO"
