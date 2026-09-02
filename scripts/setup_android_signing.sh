#!/usr/bin/env bash
#
# Provision the key every Android build from CI is signed with.
#
# A phone installs a build over the one before only when both carry the same
# signature, and Android's own debug key is minted per machine, so CI runners
# would each sign with a key of their own. This makes one, keeps it out of the
# repository, and hands it to CI as two secrets.
#
# Idempotent: an existing keystore is reused rather than replaced -- replacing
# it is exactly what forces every phone to uninstall.
#
#   bash scripts/setup_android_signing.sh            # do it
#   bash scripts/setup_android_signing.sh --help     # this
#
set -euo pipefail

REPO="${REPO:-toots/tsync}"
KEYSTORE="${KEYSTORE:-$HOME/.config/tsync/android-release.jks}"

case "${1:-}" in
  --help|-h) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

if [ -f "$KEYSTORE" ]; then
  echo "using the keystore at $KEYSTORE"
  read -r -s -p "its password: " PASSWORD; echo
else
  mkdir -p "$(dirname "$KEYSTORE")"
  PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')"
  keytool -genkeypair -keystore "$KEYSTORE" -alias tsync -keyalg RSA -keysize 4096 \
    -validity 10000 -storepass "$PASSWORD" -keypass "$PASSWORD" -dname "CN=tsync"
  echo "made $KEYSTORE -- back it up: a lost key means every phone reinstalls"
  echo "its password, kept only here and in the GitHub secret: $PASSWORD"
fi

base64 < "$KEYSTORE" | tr -d '\n' | gh secret set ANDROID_KEYSTORE_B64 -R "$REPO"
printf '%s' "$PASSWORD" | gh secret set ANDROID_KEYSTORE_PASSWORD -R "$REPO"
echo "secrets set on $REPO"
