#!/usr/bin/env bash
# Interactive setup for tsync on Linux
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tsync"
CONFIG_FILE="$CONFIG_DIR/config.json"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

echo "tsync configuration"
echo "─────────────────────────────────────"

read -rp "S3 bucket name: " BUCKET
read -rp "S3 key prefix [tsync]: " PREFIX
PREFIX="${PREFIX:-tsync}"
read -rp "AWS region [us-east-1]: " REGION
REGION="${REGION:-us-east-1}"
read -rp "Domain name(s, comma-separated) [Default]: " DOMAINS_RAW
DOMAINS_RAW="${DOMAINS_RAW:-Default}"
read -rp "Enable versioning (trash on delete)? [y/N]: " VERSIONING_RAW
VERSIONING="false"
[[ "$VERSIONING_RAW" =~ ^[Yy] ]] && VERSIONING="true"

read -rp "AWS Access Key ID: " ACCESS_KEY_ID
read -rsp "AWS Secret Access Key: " SECRET_ACCESS_KEY
echo

# Build domains JSON array
DOMAINS_JSON="["
first=1
IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS_RAW"
for d in "${DOMAIN_LIST[@]}"; do
    d="${d## }"; d="${d%% }"
    [[ $first -eq 1 ]] && first=0 || DOMAINS_JSON+=","
    DOMAINS_JSON+="{\"name\":\"$d\"}"
done
DOMAINS_JSON+="]"

cat > "$CONFIG_FILE" <<EOF
{
  "bucket": "$BUCKET",
  "prefix": "$PREFIX",
  "awsRegion": "$REGION",
  "versioning": $VERSIONING,
  "accessKeyId": "$ACCESS_KEY_ID",
  "secretAccessKey": "$SECRET_ACCESS_KEY",
  "domains": $DOMAINS_JSON
}
EOF
chmod 600 "$CONFIG_FILE"

echo ""
echo "Config saved to $CONFIG_FILE"
echo "Run 'tsync start' to mount."
