#!/usr/bin/env bash
#
# Interactive setup: defines your first store in terraform.tfvars, provisions the
# S3 bucket that holds Terraform state (bootstrap/), and runs `terraform init`
# against that remote backend.
#
# Add more stores — for multiple domains or redundant storage — by adding entries
# to the `stores` map in terraform.tfvars, then re-apply. Review the plan and
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

prompt REGION "AWS region" "us-east-1"

# AWS account id seeds globally-unique bucket-name defaults. Empty if the CLI or
# credentials aren't available — then the bucket prompts have no default.
ACCOUNT=""
if command -v aws >/dev/null 2>&1; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
fi

# ── Store definition ───────────────────────────────────────────────────────

write_tfvars=1
if [ -f "$TFVARS" ]; then
  read -rp "$TFVARS already exists. Overwrite? [y/N]: " ov
  case "$ov" in [yY]*) ;; *) echo "Keeping existing $TFVARS — add more stores by hand."; write_tfvars=0 ;; esac
fi

if [ "$write_tfvars" -eq 1 ]; then
  prompt STORE "Store name (short id, e.g. files or media)" "files"
  [ -n "$ACCOUNT" ] && STORE_BUCKET_DEFAULT="tsync-${STORE}-${ACCOUNT}-${REGION}" || STORE_BUCKET_DEFAULT=""
  prompt BUCKET "S3 bucket name for this store" "$STORE_BUCKET_DEFAULT"
  [ -n "$BUCKET" ] || {
    echo "bucket is required" >&2
    exit 1
  }
  read -rp "Create the store bucket? [Y/n] (n = use a pre-existing bucket): " cb
  case "$cb" in [nN]*) CREATE_BUCKET=false ;; *) CREATE_BUCKET=true ;; esac
  prompt PREFIX "tsync domain prefix (leave blank if the domain has none)" ""

  if [ -n "$PREFIX" ]; then
    SHARES_PREFIX="${PREFIX%/}/.shares/"
  else
    SHARES_PREFIX=".shares/"
  fi

  cat >"$TFVARS" <<EOF
region = "$REGION"

stores = {
  $STORE = {
    bucket        = "$BUCKET"
    create_bucket = $CREATE_BUCKET
    shares_prefix = "$SHARES_PREFIX"

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
  echo "Wrote $TFVARS"

  if [ "$CREATE_BUCKET" = false ] && command -v aws >/dev/null 2>&1; then
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
echo "Terraform state is kept in S3 (see bootstrap/)."
[ -n "$ACCOUNT" ] && STATE_BUCKET_DEFAULT="tsync-tfstate-${ACCOUNT}-${REGION}" || STATE_BUCKET_DEFAULT=""
prompt STATE_BUCKET "S3 bucket for Terraform state (globally unique)" "$STATE_BUCKET_DEFAULT"
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
  cat >"$BACKEND_HCL" <<EOF
bucket = "$STATE_BUCKET"
region = "$REGION"
EOF
  echo "Wrote $BACKEND_HCL"
fi

read -rp "Create the state bucket now (skip if it already exists)? [Y/n]: " mkstate
case "$mkstate" in
  [nN]*)
    echo "Skipping. Create it later with:"
    echo "  terraform -chdir=bootstrap init"
    echo "  terraform -chdir=bootstrap apply -var state_bucket=$STATE_BUCKET -var region=$REGION"
    ;;
  *)
    terraform -chdir=bootstrap init
    terraform -chdir=bootstrap apply -var state_bucket="$STATE_BUCKET" -var region="$REGION"
    ;;
esac

# ── Init main config against the remote backend ────────────────────────────

echo
terraform init -backend-config="$BACKEND_HCL"

cat <<'EOF'

Done. Next steps:
  terraform plan     # review what will be created/changed
  terraform apply    # provision the store(s)

Then wire each store into its tsync domain config (accessKeyId, bucket, share.url):
  terraform output stores
  terraform output -json secret_access_keys | jq -r '.["<store>"]'
EOF
