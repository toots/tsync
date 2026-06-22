#!/usr/bin/env bash
set -euo pipefail

CONTAINER="$HOME/Library/Group Containers/group.com.toots.tsync"
CONFIG="$CONTAINER/config.json"

echo "tsync configuration"
echo "-------------------"

read -rp "S3 bucket name: " bucket
read -rp "S3 key prefix [tsync]: " prefix
prefix="${prefix:-tsync}"
read -rp "AWS region [us-east-1]: " region
region="${region:-us-east-1}"
read -rp "Domain name [Music Production]: " domain
domain="${domain:-Music Production}"
read -rp "Enable versioning? (y/N): " versioning_input
versioning="false"
[[ "${versioning_input,,}" == "y" ]] && versioning="true"

echo ""
read -rp "AWS Access Key ID: " aws_key
read -rsp "AWS Secret Access Key: " aws_secret
echo ""

# Write config.json
mkdir -p "$CONTAINER"
cat > "$CONFIG" << EOF
{
  "bucket": "$bucket",
  "prefix": "$prefix",
  "awsRegion": "$region",
  "versioning": $versioning,
  "domains": [
    { "name": "$domain" }
  ]
}
EOF
echo "Config written to $CONFIG"

# Store credentials in Keychain (app group accessible)
security add-generic-password \
  -s "com.toots.tsync.aws" \
  -a "default" \
  -G "group.com.toots.tsync" \
  -w "${aws_key}:${aws_secret}" \
  -U 2>/dev/null && echo "Credentials stored in Keychain" \
  || { echo "Warning: could not store credentials in Keychain (run from a signed context or enter them via tsync init later)"; }

echo ""
echo "Done. Launch TsyncApp from Xcode (⌘R) or from /Applications to register the FileProvider domain."
echo "Then ~/Library/CloudStorage/tsync - $domain/ will appear in Finder."
