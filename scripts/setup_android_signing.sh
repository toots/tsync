#!/usr/bin/env bash
#
# Provision the key every published tsync APK is signed with (10 §5.4).
#
# A phone refuses an update signed by another key, so this key is made once
# and kept: the keystore stays out of the repository and goes to CI as two
# secrets.
#
# Idempotent: an existing keystore is reused rather than replaced -- replacing
# it forces every phone to uninstall and reinstall the app.
#
#   bash scripts/setup_android_signing.sh            # do it
#   bash scripts/setup_android_signing.sh --help     # this
#
set -euo pipefail

REPO="${REPO:-toots/tsync}"
KEYSTORE="${KEYSTORE:-$HOME/.config/tsync/android-release.jks}"
PASSWORD_FILE="${PASSWORD_FILE:-$KEYSTORE.password}"

case "${1:-}" in
  --help | -h) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

if [ -f "$KEYSTORE" ] && [ -f "$PASSWORD_FILE" ]; then
  echo "using the keystore at $KEYSTORE"
else
  if [ -f "$KEYSTORE" ]; then
    echo "$KEYSTORE exists without $PASSWORD_FILE; refusing to replace it" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$KEYSTORE")"
  (umask 077 && openssl rand -hex 24 > "$PASSWORD_FILE")
  keytool -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 \
    -storepass:file "$PASSWORD_FILE" -alias tsync -dname "CN=tsync" \
    -keyalg RSA -keysize 4096 -validity 36500
  chmod 600 "$KEYSTORE"
  echo "made $KEYSTORE -- back it up with $PASSWORD_FILE: losing them means every phone reinstalls"
fi

base64 < "$KEYSTORE" | tr -d '\n' | gh secret set ANDROID_KEYSTORE_B64 -R "$REPO"
tr -d '\n' < "$PASSWORD_FILE" | gh secret set ANDROID_KEYSTORE_PASSWORD -R "$REPO"
echo "secrets set on $REPO"
