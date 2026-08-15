#!/usr/bin/env bash
#
# Interactive setup: defines your first store in terraform.tfvars, provisions the
# bucket that holds Terraform state, activates the matching backend, and runs
# `terraform init`. Works for either cloud — S3 or GCS.
#
# Add more stores — for multiple domains or redundant storage — by adding entries
# to the stores map in terraform.tfvars, then re-apply. Review the plan and
# `terraform apply` yourself after this finishes.

set -euo pipefail
cd "$(dirname "$0")"

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

    # Opt-in: transition ALL objects to the ARCHIVE (cold) storage class after
    # this many days.
    # archive_after_days = 30
  }
}
EOF
  fi
  echo "Wrote $TFVARS"

  # Warn if a pre-existing S3 bucket already has lifecycle rules apply would
  # replace. (GCS lifecycle is only managed on buckets this config creates.)
  if [ "$CLOUD" = s3 ] && [ "$CREATE_BUCKET" = false ] && command -v aws >/dev/null 2>&1; then
    if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
      echo "WARNING: cannot access bucket '$BUCKET' (may not exist, or no credentials)." >&2
    else
      existing=$(aws s3api get-bucket-lifecycle-configuration \
        --bucket "$BUCKET" --region "$REGION" 2>/dev/null || true)
      if [ -n "$existing" ]; then
        echo
        echo "WARNING: this bucket already has lifecycle rules:"
        echo "$existing"
        echo "terraform apply will REPLACE them. Copy them into extra_lifecycle_rules"
        echo "for the '$STORE' store in $TFVARS, or set manage_lifecycle = false."
      fi
    fi
  fi
fi

# ── Remote state bucket ────────────────────────────────────────────────────

echo
echo "Terraform state is kept in the ${CLOUD} state bucket (see bootstrap-${CLOUD}/)."
if [ "$CLOUD" = s3 ]; then
  [ -n "$SEED" ] && STATE_BUCKET_DEFAULT="tsync-tfstate-${SEED}" || STATE_BUCKET_DEFAULT=""
else
  STATE_BUCKET_DEFAULT="${PROJECT}-tfstate"
fi
prompt STATE_BUCKET "Bucket for Terraform state (globally unique)" "$STATE_BUCKET_DEFAULT"
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
  create_cmd=(terraform -chdir=bootstrap-s3 apply -var state_bucket="$STATE_BUCKET" -var region="$REGION")
else
  create_cmd=(terraform -chdir=bootstrap-gcs apply -var project="$PROJECT" -var location="$LOCATION" -var state_bucket="$STATE_BUCKET")
fi

read -rp "Create the state bucket now (skip if it already exists)? [Y/n]: " mkstate
case "$mkstate" in
  [nN]*)
    echo "Skipping. Create it later with:"
    echo "  terraform -chdir=bootstrap-${CLOUD} init"
    echo "  ${create_cmd[*]}"
    ;;
  *)
    terraform -chdir="bootstrap-${CLOUD}" init
    "${create_cmd[@]}"
    ;;
esac

# ── Init main config against the remote backend ────────────────────────────

# Activate the chosen backend block (shipped as a template; only one may exist).
[ -f "backend-${CLOUD}.tf" ] || cp "backend-${CLOUD}.tf.example" "backend-${CLOUD}.tf"

echo
terraform init -backend-config="$BACKEND_HCL"

if [ "$CLOUD" = s3 ]; then
  cat <<'EOF'

Done. Next steps:
  terraform plan     # review what will be created/changed
  terraform apply    # provision the store(s)

Then set these on the s3 backend in your tsync config (or let `tsync config --edit`
pull them for you): bucket, accessKeyId, secretAccessKey, shareUrl.
  terraform output stores
  terraform output -json secret_access_keys | jq -r '.["<store>"]'
EOF
else
  cat <<'EOF'

Done. Next steps:
  terraform plan     # review what will be created/changed
  terraform apply    # provision the store(s)

Then set these on the gcs backend in your tsync config (or let `tsync config --edit`
pull them for you): bucket, serviceAccountKey, shareUrl.
  terraform output gcs_stores
  terraform output -json gcs_service_account_keys | jq -r '.["<store>"]'
EOF
fi
