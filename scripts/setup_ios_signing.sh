#!/usr/bin/env bash
#
# Set the secrets release-ios signs and uploads with (10 §5.6): the App Store
# Connect API key, its id and issuer, the identifiers of ios.md §3.1, the
# export compliance code and the development certificate of 10 §5.6.
#
# The key and the .p12 are made by hand, as ios/RELEASING.md states; the
# .p12's password is asked for. The identifiers are read from the file
# ios/app/run-device.sh reads.
#
#   bash scripts/setup_ios_signing.sh AuthKey_<KEYID>.p8 <issuer-uuid> <development.p12>
#   bash scripts/setup_ios_signing.sh --help     # this
#
set -euo pipefail

REPO="${REPO:-toots/tsync}"
IDENTIFIERS="${TSYNC_IOS_IDENTIFIERS:-$HOME/.config/tsync/ios-identifiers}"

case "${1:-}" in
  --help | -h | "") sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
key=$1 issuer=${2:?the issuer UUID, above the key list in App Store Connect}
p12=${3:?the development certificate exported as .p12, as ios/RELEASING.md states}

key_id=$(basename "$key" .p8)
key_id=${key_id#AuthKey_}
[ "${#key_id}" = 10 ] || { echo "$key is not named AuthKey_<10-character key id>.p8" >&2; exit 1; }
grep -q 'BEGIN PRIVATE KEY' "$key" || { echo "$key holds no private key" >&2; exit 1; }
read -rsp "password of $p12: " p12_password
echo
# One identity, so the runner's keychain offers Xcode nothing else.
identities=$(openssl pkcs12 -in "$p12" -passin fd:3 -nokeys -legacy 3<<< "$p12_password" 2> /dev/null \
  || openssl pkcs12 -in "$p12" -passin fd:3 -nokeys 3<<< "$p12_password") \
  || { echo "$p12 does not open with that password" >&2; exit 1; }
grep -c 'BEGIN CERTIFICATE' <<< "$identities" | grep -qx 1 \
  || { echo "$p12 must hold exactly one certificate" >&2; exit 1; }
grep -q 'Apple Development' <<< "$identities" \
  || { echo "$p12 is not an Apple Development certificate" >&2; exit 1; }

# shellcheck source=/dev/null
. "$IDENTIFIERS"
for name in TSYNC_TEAM_ID TSYNC_APP_ID TSYNC_APP_GROUP; do
  [ -n "${!name:-}" ] || { echo "$IDENTIFIERS does not export $name" >&2; exit 1; }
done

base64 < "$key" | tr -d '\n' | gh secret set IOS_ASC_KEY_P8 -R "$REPO"
printf %s "$key_id" | gh secret set IOS_ASC_KEY_ID -R "$REPO"
printf %s "$issuer" | gh secret set IOS_ASC_ISSUER_ID -R "$REPO"
printf %s "$TSYNC_TEAM_ID" | gh secret set IOS_TEAM_ID -R "$REPO"
printf %s "$TSYNC_APP_ID" | gh secret set IOS_APP_ID -R "$REPO"
printf %s "$TSYNC_APP_GROUP" | gh secret set IOS_APP_GROUP -R "$REPO"
# 10 §5.6: the code exists once App Store Connect issued it.
if [ -n "${TSYNC_EXPORT_COMPLIANCE_CODE:-}" ]; then
  printf %s "$TSYNC_EXPORT_COMPLIANCE_CODE" | gh secret set IOS_EXPORT_COMPLIANCE_CODE -R "$REPO"
else
  echo "no TSYNC_EXPORT_COMPLIANCE_CODE: each TestFlight build waits for the encryption question"
fi
base64 < "$p12" | tr -d '\n' | gh secret set IOS_DEV_CERT_P12 -R "$REPO"
printf %s "$p12_password" | gh secret set IOS_DEV_CERT_PASSWORD -R "$REPO"
echo "secrets set on $REPO; the .p8 cannot be downloaded again, so keep it or delete it knowingly"
