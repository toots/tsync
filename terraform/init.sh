#!/usr/bin/env bash
#
# Interactive setup: defines your first store in terraform.tfvars, provisions the
# bucket that holds the state, activates the matching backend, and initialises
# the deployment. Works for either cloud — S3 or GCS — and with either CLI.
#
# Add more stores — for multiple domains or redundant storage — by adding entries
# to the stores map in terraform.tfvars, then re-apply. This never applies the
# deployment: review the plan and apply it yourself afterwards.

set -euo pipefail
cd "$(dirname "$0")"

. ./tf-cli.sh
TF=$(tf_cli) || {
  echo "Neither tofu nor terraform is installed${TSYNC_TF:+ (TSYNC_TF=$TSYNC_TF was not found)}." >&2
  exit 1
}
echo "Using $TF."

TFVARS="terraform.tfvars"
BACKEND_HCL="backend.hcl"

prompt() { # prompt VAR "question" ["default"]
  local __var=$1 q=$2 def=${3:-} ans
  if [ -n "$def" ]; then
    read -rp "$q [$def]: " ans
    ans=${ans:-$def}
  else
    read -rp "$q: " ans
  fi
  printf -v "$__var" '%s' "$ans"
}

# ── Cloud ──────────────────────────────────────────────────────────────────

while :; do
  prompt CLOUD "Cloud for state + stores (s3/gcs)" "s3"
  case "$CLOUD" in s3 | gcs) break ;; *) echo "  choose s3 or gcs" ;; esac
done

# Only one backend block may be active.
OTHER=$([ "$CLOUD" = s3 ] && echo gcs || echo s3)
if [ -f "backend-${OTHER}.tf" ]; then
  echo "backend-${OTHER}.tf is active — remove it before setting up ${CLOUD} state." >&2
  exit 1
fi

# Cloud-specific location/identity. SEED (s3 only) seeds globally-unique
# bucket-name defaults; on GCS the project id leads the name instead.
SEED=""
if [ "$CLOUD" = s3 ]; then
  prompt REGION "AWS region" "us-east-1"
  ACCOUNT=""
  if command -v aws >/dev/null 2>&1; then
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
  fi
  SEED="${ACCOUNT:+${ACCOUNT}-${REGION}}"
else
  DEF_PROJECT=""
  command -v gcloud >/dev/null 2>&1 && DEF_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  prompt PROJECT "GCP project id" "$DEF_PROJECT"
  [ -n "$PROJECT" ] || {
    echo "project is required" >&2
    exit 1
  }
  prompt LOCATION "Bucket location (e.g. US, us-central1)" "US"
fi

# ── Store definition ───────────────────────────────────────────────────────

write_tfvars=1
if [ -f "$TFVARS" ]; then
  read -rp "$TFVARS already exists. Overwrite? [y/N]: " ov
  case "$ov" in [yY]*) ;; *) echo "Keeping existing $TFVARS — add more stores by hand."; write_tfvars=0 ;; esac
fi

if [ "$write_tfvars" -eq 1 ]; then
  prompt STORE "Store name (short id, e.g. files or media)" "files"
  if [ "$CLOUD" = s3 ]; then
    [ -n "$SEED" ] && STORE_BUCKET_DEFAULT="tsync-${STORE}-${SEED}" || STORE_BUCKET_DEFAULT=""
  else
    STORE_BUCKET_DEFAULT="${PROJECT}-${STORE}"
  fi
  prompt BUCKET "Bucket name for this store" "$STORE_BUCKET_DEFAULT"
  [ -n "$BUCKET" ] || {
    echo "bucket is required" >&2
    exit 1
  }
  read -rp "Create the store bucket? [Y/n] (n = use a pre-existing bucket): " cb
  case "$cb" in [nN]*) CREATE_BUCKET=false ;; *) CREATE_BUCKET=true ;; esac

  if [ "$CLOUD" = s3 ]; then
    cat >"$TFVARS" <<EOF
region = "$REGION"

stores = {
  $STORE = {
    bucket        = "$BUCKET"
    create_bucket = $CREATE_BUCKET

    # If this is a pre-existing bucket with lifecycle rules, list them here so
    # they are preserved — the module owns the whole lifecycle config and apply
    # replaces it. See README.md > "Bucket lifecycle" for the schema.
    # extra_lifecycle_rules = [{
    #   id          = "glacier-ir"
    #   transitions = [{ days = 30, storage_class = "GLACIER_IR" }]
    # }]
  }
}
EOF
  else
    cat >"$TFVARS" <<EOF
gcp_project = "$PROJECT"
gcp_region  = "$LOCATION"

gcs_stores = {
  $STORE = {
    bucket        = "$BUCKET"
    create_bucket = $CREATE_BUCKET

    # Opt-in: transition one domain's chunks to the ARCHIVE (cold) storage
    # class after N days. Keyed by tsync domain name; nothing else is archived.
    # archive_domains = { "My Domain" = { after_days = 30 } }
  }
}
EOF
  fi
  echo "Wrote $TFVARS"

  # An adopted S3 bucket has two documents that applying replaces whole.
  if [ "$CLOUD" = s3 ] && [ "$CREATE_BUCKET" = false ]; then
    if ! command -v aws >/dev/null 2>&1; then
      echo "WARNING: no aws CLI, so '$BUCKET' was not looked at. Applying REPLACES its" >&2
      echo "lifecycle and notification configurations unless you decline them" >&2
      echo "(manage_lifecycle = false, manage_notifications = false)." >&2
    elif ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
      echo "WARNING: cannot access bucket '$BUCKET' (may not exist, or no credentials)." >&2
    else
      existing=$(aws s3api get-bucket-lifecycle-configuration \
        --bucket "$BUCKET" --region "$REGION" 2>/dev/null || true)
      if [ -n "$existing" ]; then
        echo
        echo "WARNING: this bucket already has lifecycle rules:"
        echo "$existing"
        echo "Applying will REPLACE them. Copy them into extra_lifecycle_rules"
        echo "for the '$STORE' store in $TFVARS, or set manage_lifecycle = false."
      fi
      # An empty configuration answers "{}" or nothing, depending on the CLI.
      existing=$(aws s3api get-bucket-notification-configuration \
        --bucket "$BUCKET" --region "$REGION" --output json 2>/dev/null | tr -d ' \n' || true)
      if [ -n "$existing" ] && [ "$existing" != "{}" ]; then
        echo
        echo "WARNING: this bucket already has notifications:"
        echo "$existing"
        echo "Applying will REPLACE them. Set manage_notifications = false for the"
        echo "'$STORE' store in $TFVARS and add the tsync/ trigger to your own"
        echo "(README.md > If you wire the trigger yourself)."
      fi
    fi
  fi

  if [ "$CLOUD" = gcs ] && [ "$CREATE_BUCKET" = false ]; then
    echo
    echo "NOTE: the lifecycle of an adopted GCS bucket stays yours. Add one rule to it:"
    echo "  abort incomplete multipart uploads after 1 day"
    echo "and nothing that deletes objects under tsync/."
  fi
fi

# ── Remote state bucket ────────────────────────────────────────────────────

echo
echo "The state is kept in the ${CLOUD} state bucket (see bootstrap-${CLOUD}/)."
if [ "$CLOUD" = s3 ]; then
  [ -n "$SEED" ] && STATE_BUCKET_DEFAULT="tsync-tfstate-${SEED}" || STATE_BUCKET_DEFAULT=""
else
  STATE_BUCKET_DEFAULT="${PROJECT}-tfstate"
fi
prompt STATE_BUCKET "Bucket for the state (globally unique)" "$STATE_BUCKET_DEFAULT"
[ -n "$STATE_BUCKET" ] || {
  echo "state bucket is required" >&2
  exit 1
}

write_backend=1
if [ -f "$BACKEND_HCL" ]; then
  read -rp "$BACKEND_HCL already exists. Overwrite? [y/N]: " ob
  case "$ob" in [yY]*) ;; *) write_backend=0 ;; esac
fi
if [ "$write_backend" -eq 1 ]; then
  if [ "$CLOUD" = s3 ]; then
    cat >"$BACKEND_HCL" <<EOF
bucket = "$STATE_BUCKET"
region = "$REGION"
EOF
  else
    cat >"$BACKEND_HCL" <<EOF
bucket = "$STATE_BUCKET"
EOF
  fi
  echo "Wrote $BACKEND_HCL"
fi

if [ "$CLOUD" = s3 ]; then
  create_cmd=("$TF" -chdir=bootstrap-s3 apply -var state_bucket="$STATE_BUCKET" -var region="$REGION")
else
  create_cmd=("$TF" -chdir=bootstrap-gcs apply -var project="$PROJECT" -var location="$LOCATION" -var state_bucket="$STATE_BUCKET")
fi

read -rp "Create the state bucket now (skip if it already exists)? [Y/n]: " mkstate
case "$mkstate" in
  [nN]*)
    echo "Skipping. Create it later with:"
    echo "  $TF -chdir=bootstrap-${CLOUD} init"
    echo "  ${create_cmd[*]}"
    ;;
  *)
    "$TF" -chdir="bootstrap-${CLOUD}" init
    "${create_cmd[@]}"
    ;;
esac

# ── Init main config against the remote backend ────────────────────────────

# Activate the chosen backend block (shipped as a template; only one may exist).
[ -f "backend-${CLOUD}.tf" ] || cp "backend-${CLOUD}.tf.example" "backend-${CLOUD}.tf"

echo
"$TF" init -backend-config="$BACKEND_HCL"

cat <<EOF

Done. Next steps:
  $TF plan     # review what will be created/changed
  $TF apply    # provision the store(s)

Then set the store's fields on the $CLOUD backend in your tsync config, or let
\`tsync config --edit\` fill them from this directory:
  $TF output stores
  $TF output -json store_secrets | jq '.["<store>"]'
EOF
