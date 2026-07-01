#!/usr/bin/env bash
set -euo pipefail

# Locate config + credentials, merge into TSYNC_CONFIG_JSON, run tests in Docker.
#
# Config resolution order:
#   1. $TSYNC_CONFIG_JSON already set in env → use as-is
#   2. macOS app group container (default install location)
#   3. XDG config dir (~/.config/tsync/)
#   4. Interactive prompts

MACOS_DIR="$HOME/Library/Group Containers/group.com.toots.tsync"
XDG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tsync"

if [[ -z "${TSYNC_CONFIG_JSON:-}" ]]; then
  # Find config.json
  if [[ -f "$MACOS_DIR/config.json" ]]; then
    CONFIG_FILE="$MACOS_DIR/config.json"
    CREDS_FILE="$MACOS_DIR/credentials.json"
  elif [[ -f "$XDG_DIR/config.json" ]]; then
    CONFIG_FILE="$XDG_DIR/config.json"
    CREDS_FILE="$XDG_DIR/credentials.json"
  else
    echo "No config.json found. Enter config values interactively."
    read -rp "  AWS bucket:     " BUCKET
    read -rp "  Backend prefix:  " PREFIX
    read -rp "  AWS region:     " REGION
    read -rp "  Domain name:    " DOMAIN
    read -rp "  Versioning (true/false): " VERSIONING
    read -rp "  Access key ID:  " ACCESS_KEY
    read -rsp "  Secret key:     " SECRET_KEY; echo
    export TSYNC_CONFIG_JSON
    TSYNC_CONFIG_JSON=$(jq -n \
      --arg bucket "$BUCKET" \
      --arg prefix "$PREFIX" \
      --arg region "$REGION" \
      --argjson versioning "$VERSIONING" \
      --arg domain "$DOMAIN" \
      --arg ak "$ACCESS_KEY" \
      --arg sk "$SECRET_KEY" \
      '{bucket:$bucket,prefix:$prefix,awsRegion:$region,versioning:$versioning,
        domains:[{name:$domain}],accessKeyId:$ak,secretAccessKey:$sk}')
  fi

  if [[ -z "${TSYNC_CONFIG_JSON:-}" ]]; then
    # Merge config + credentials files
    if [[ -f "${CREDS_FILE:-}" ]]; then
      TSYNC_CONFIG_JSON=$(jq -s '.[0] * .[1]' "$CONFIG_FILE" "$CREDS_FILE")
    else
      TSYNC_CONFIG_JSON=$(cat "$CONFIG_FILE")
    fi

    # Prompt for credentials if still missing
    if ! echo "$TSYNC_CONFIG_JSON" | jq -e '.accessKeyId' > /dev/null 2>&1; then
      read -rp "  Access key ID:  " ACCESS_KEY
      read -rsp "  Secret key:     " SECRET_KEY; echo
      TSYNC_CONFIG_JSON=$(echo "$TSYNC_CONFIG_JSON" | jq \
        --arg ak "$ACCESS_KEY" --arg sk "$SECRET_KEY" \
        '. + {accessKeyId:$ak, secretAccessKey:$sk}')
    fi

    export TSYNC_CONFIG_JSON
  fi
fi

cd "$(dirname "$0")"
exec docker compose run --rm dev bash -c \
  "eval \$(opam env) && cd /workspace && bash linux/test_lifecycle.sh"
