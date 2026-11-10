#!/usr/bin/env bash
#
# Set the secrets release-ios signs and uploads with (10 §5.6): the App Store
# Connect API key, its id and issuer, and the identifiers of ios.md §3.1.
#
# The key is made by hand, with the Admin role cloud signing needs, as
# ios/RELEASING.md states. The identifiers are read from the file
# ios/app/run-device.sh reads.
#
#   bash scripts/setup_ios_signing.sh AuthKey_<KEYID>.p8 <issuer-uuid>
#   bash scripts/setup_ios_signing.sh --help     # this
#
set -euo pipefail

REPO="${REPO:-toots/tsync}"
IDENTIFIERS="${TSYNC_IOS_IDENTIFIERS:-$HOME/.config/tsync/ios-identifiers}"

case "${1:-}" in
  --help | -h | "") sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
key=$1 issuer=${2:?the issuer UUID, above the key list in App Store Connect}

key_id=$(basename "$key" .p8)
key_id=${key_id#AuthKey_}
[ "${#key_id}" = 10 ] || { echo "$key is not named AuthKey_<10-character key id>.p8" >&2; exit 1; }
grep -q 'BEGIN PRIVATE KEY' "$key" || { echo "$key holds no private key" >&2; exit 1; }

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
echo "secrets set on $REPO; the .p8 cannot be downloaded again, so keep it or delete it knowingly"
