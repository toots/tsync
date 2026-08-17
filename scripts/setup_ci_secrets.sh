#!/usr/bin/env bash
#
# Provision the buckets, scoped credentials and GitHub secrets the tsync backend
# conformance and stress jobs need.
#
# Idempotent: re-running adopts whatever already exists rather than failing, and
# only mints a credential when there is none to reuse.
#
# Nothing here touches tsync-503522-files or any other bucket you already use.
# The credentials it creates can reach the test buckets and nothing else, which
# is the point: CI holds them, and CI wipes what it writes.
#
#   bash scripts/setup_ci_secrets.sh            # do it
#   bash scripts/setup_ci_secrets.sh --dry-run  # print what it would do
#   bash scripts/setup_ci_secrets.sh --help     # this
#
set -euo pipefail

REPO="${REPO:-toots/tsync}"
GCP_PROJECT="${GCP_PROJECT:-tsync-503522}"
GCS_LOCATION="${GCS_LOCATION:-us-central1}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Bucket names are globally unique, so they carry the project to stay distinct.
GCS_BUCKET="${GCS_BUCKET:-tsync-ci-${GCP_PROJECT##*-}}"
S3_BUCKET="${S3_BUCKET:-tsync-ci-${GCP_PROJECT##*-}}"
GCS_SA="${GCS_SA:-tsync-ci}"
AWS_IAM_USER="${AWS_IAM_USER:-tsync-ci}"

# CI writes under tsync/ci-<run id>/ and deletes it again, but a cancelled run
# leaves its prefix behind. Anything older than this goes on its own, so a
# forgotten run cannot accrue cost indefinitely.
EXPIRE_DAYS="${EXPIRE_DAYS:-2}"

# The chunk verifier is deployed onto the CI buckets so conformance has
# something real to trigger: two of the things this project leans on -- the
# whole-store sweep and the deletes a collection hands over -- are a client
# writing an object and trusting a function to act on it, and nothing else
# proves that wiring exists.
#
# Its own terraform state, and never the one next door: that one holds real
# stores, and an apply pointed at CI buckets with the wrong state is how they
# would be reached. The bucket is the same, the prefix is not.
DEPLOY_FUNCTIONS="${DEPLOY_FUNCTIONS:-1}"
TF_STATE_PREFIX="${TF_STATE_PREFIX:-tsync-ci}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"

usage() {
  sed -n '3,15p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
  exit "${1:-0}"
}

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  -h | --help) usage ;;
  "") ;;
  *) printf 'unknown argument: %s\n\n' "$1" >&2; usage 2 ;;
esac

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [ $DRY_RUN = 1 ]; then printf '  + %s\n' "$*"; else eval "$@"; fi; }

# Freshly created GCP principals are not visible to every service at once, and
# the failure reads as a flat 400 rather than anything retryable, so waiting is
# the only way to tell "not yet" from "wrong". Same reasoning as the AWS access
# key below.
retry() {
  local what=$1; shift
  local attempt err
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if [ $DRY_RUN = 1 ]; then printf '  + %s\n' "$*"; return 0; fi
    if err=$(eval "$@" 2>&1); then return 0; fi
    sleep 5
  done
  die "$what did not succeed after 10 attempts: $(printf '%s' "$err" | tail -1)"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT   # holds a private key for a moment; never persisted

# ---------------------------------------------------------------- preflight --

say "Checking prerequisites"
command -v gh      >/dev/null || die "gh not found"
command -v gcloud  >/dev/null || die "gcloud not found"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
gh repo view "$REPO" >/dev/null 2>&1 || die "cannot see $REPO with this gh login"
gcloud auth print-access-token >/dev/null 2>&1 \
  || die "gcloud is not logged in (gcloud auth login)"
info "gh, gcloud: ok, repo $REPO reachable"

WANT_S3=1
if ! command -v aws >/dev/null || ! aws sts get-caller-identity >/dev/null 2>&1; then
  WANT_S3=0
  warn "aws cli missing or not configured -- skipping the S3 half."
  warn "The s3 backend's put_if_absent stays unverified until it is set up."
fi

# Either binary drives the same configuration; the README says as much for a
# real deployment, so the test stack is no different.
TF=""
if [ "$DEPLOY_FUNCTIONS" = 1 ]; then
  for candidate in tofu terraform; do
    command -v "$candidate" >/dev/null && { TF="$candidate"; break; }
  done
  if [ -z "$TF" ]; then
    DEPLOY_FUNCTIONS=0
    warn "neither tofu nor terraform found -- not deploying the chunk verifier."
    warn "Conformance will report the serverless half as not run."
  else
    info "$TF: ok, will deploy the chunk verifier onto the CI bucket(s)"
  fi
fi

if [ $DRY_RUN = 0 ]; then
  say "About to create"
  info "GCS bucket        gs://$GCS_BUCKET           (project $GCP_PROJECT)"
  info "GCS service acct  $GCS_SA@$GCP_PROJECT.iam.gserviceaccount.com"
  [ $WANT_S3 = 1 ] && info "S3 bucket         s3://$S3_BUCKET            (region $AWS_REGION)"
  [ $WANT_S3 = 1 ] && info "AWS IAM user      $AWS_IAM_USER"
  info "GitHub secrets on $REPO"
  info "Objects auto-expire after $EXPIRE_DAYS day(s)."
  printf '\nProceed? [y/N] '
  read -r reply
  case "$reply" in [yY]*) ;; *) die "aborted" ;; esac
fi

# --------------------------------------------------------------------- GCS --

say "GCS bucket"
if gcloud storage buckets describe "gs://$GCS_BUCKET" --project "$GCP_PROJECT" >/dev/null 2>&1; then
  info "gs://$GCS_BUCKET exists, reusing"
else
  run gcloud storage buckets create "gs://$GCS_BUCKET" \
    --project "$GCP_PROJECT" --location "$GCS_LOCATION" \
    --uniform-bucket-level-access
  info "created gs://$GCS_BUCKET"
fi

cat > "$WORK/lifecycle.json" <<EOF
{"lifecycle":{"rule":[{"action":{"type":"Delete"},
 "condition":{"age":$EXPIRE_DAYS}}]}}
EOF
run gcloud storage buckets update "gs://$GCS_BUCKET" \
  --lifecycle-file="$WORK/lifecycle.json" --project "$GCP_PROJECT"
info "objects expire after $EXPIRE_DAYS day(s)"

say "GCS service account"
GCS_SA_EMAIL="$GCS_SA@$GCP_PROJECT.iam.gserviceaccount.com"
if gcloud iam service-accounts describe "$GCS_SA_EMAIL" --project "$GCP_PROJECT" >/dev/null 2>&1; then
  info "$GCS_SA_EMAIL exists, reusing"
else
  run gcloud iam service-accounts create "$GCS_SA" --project "$GCP_PROJECT" \
    --display-name "'tsync CI'" \
    --description "'Reaches the tsync CI test bucket and nothing else'"
  info "created $GCS_SA_EMAIL"
  retry "service account becoming visible" \
    gcloud iam service-accounts describe "$GCS_SA_EMAIL" \
      --project "$GCP_PROJECT" '>/dev/null'
  info "visible to IAM"
fi

# Bound on the bucket, not the project: this identity must not be able to touch
# anything else in tsync-503522.
# --condition=None because the verifier's own grants are conditional, and gcloud
# refuses to guess which kind of binding an unconditional add means once a policy
# contains any: this one is meant to apply everywhere in the bucket.
retry "granting objectAdmin" \
  gcloud storage buckets add-iam-policy-binding "gs://$GCS_BUCKET" \
  --member "serviceAccount:$GCS_SA_EMAIL" --role roles/storage.objectAdmin \
  --condition=None --project "$GCP_PROJECT" '>/dev/null'
info "granted objectAdmin on gs://$GCS_BUCKET only"

say "GCS key"
# A key is write-only after creation, so there is nothing to reuse and each run
# mints one. Older keys are revoked at the very end, once the new one is proven
# and stored: revoking first would, on any later failure, leave CI holding a
# credential that no longer works and no obvious sign of why.
if [ $DRY_RUN = 1 ]; then
  info "+ gcloud iam service-accounts keys create (into a temp file)"
else
  GCS_KEYS_BEFORE=$(gcloud iam service-accounts keys list --iam-account "$GCS_SA_EMAIL" \
                      --managed-by user --project "$GCP_PROJECT" \
                      --format 'value(name)' 2>/dev/null | sed 's|.*/||' || true)
  gcloud iam service-accounts keys create "$WORK/gcs-key.json" \
    --iam-account "$GCS_SA_EMAIL" --project "$GCP_PROJECT" >/dev/null 2>&1 \
    || die "could not mint a key for $GCS_SA_EMAIL"
  info "minted a fresh key"
fi

# ---------------------------------------------------------------------- S3 --

if [ $WANT_S3 = 1 ]; then
  say "S3 bucket"
  if aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
    info "s3://$S3_BUCKET exists, reusing"
  elif [ "$AWS_REGION" = "us-east-1" ]; then
    run aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" '>/dev/null'
    info "created s3://$S3_BUCKET"
  else
    run aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" '>/dev/null'
    info "created s3://$S3_BUCKET"
  fi

  cat > "$WORK/s3-lifecycle.json" <<EOF
{"Rules":[{"ID":"expire-ci","Status":"Enabled","Filter":{"Prefix":""},
 "Expiration":{"Days":$EXPIRE_DAYS},
 "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}
EOF
  run aws s3api put-bucket-lifecycle-configuration --bucket "$S3_BUCKET" \
    --lifecycle-configuration "file://$WORK/s3-lifecycle.json"
  info "objects expire after $EXPIRE_DAYS day(s)"

  say "AWS IAM user"
  if aws iam get-user --user-name "$AWS_IAM_USER" >/dev/null 2>&1; then
    info "$AWS_IAM_USER exists, reusing"
  else
    run aws iam create-user --user-name "$AWS_IAM_USER" '>/dev/null'
    info "created $AWS_IAM_USER"
  fi

  cat > "$WORK/s3-policy.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],
  "Resource":"arn:aws:s3:::$S3_BUCKET"},
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],
  "Resource":"arn:aws:s3:::$S3_BUCKET/*"}]}
EOF
  run aws iam put-user-policy --user-name "$AWS_IAM_USER" \
    --policy-name tsync-ci-bucket --policy-document "file://$WORK/s3-policy.json"
  info "scoped to s3://$S3_BUCKET only"

  say "AWS access key"
  if [ $DRY_RUN = 1 ]; then
    info "+ aws iam create-access-key"
  else
    S3_KEYS_BEFORE=$(aws iam list-access-keys --user-name "$AWS_IAM_USER" \
                       --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true)
    # IAM allows two keys per user, so making room is sometimes unavoidable
    # before minting. The oldest goes; the other stays valid until the new one
    # is proven and stored.
    if [ "$(printf '%s\n' $S3_KEYS_BEFORE | grep -c . || true)" -ge 2 ]; then
      oldest=$(aws iam list-access-keys --user-name "$AWS_IAM_USER" \
                 --query 'sort_by(AccessKeyMetadata,&CreateDate)[0].AccessKeyId' \
                 --output text 2>/dev/null)
      aws iam delete-access-key --user-name "$AWS_IAM_USER" --access-key-id "$oldest" >/dev/null 2>&1 || true
      S3_KEYS_BEFORE=$(printf '%s\n' $S3_KEYS_BEFORE | grep -v "^$oldest$" || true)
      info "revoked the oldest key to make room"
    fi
    aws iam create-access-key --user-name "$AWS_IAM_USER" > "$WORK/s3-key.json" \
      || die "could not mint an access key for $AWS_IAM_USER"
    info "minted a fresh key"
  fi
fi

# ------------------------------------------------------------ verification --
# Credentials that cannot actually write are worse than none: CI would go red
# with an authentication error rather than a test result. So prove them before
# handing them over.

if [ $DRY_RUN = 0 ]; then
  say "Verifying the credentials work"

  CHECK="tsync/ci-setup-check/$$"
  printf 'tsync ci setup check\n' > "$WORK/probe-gcs"
  if ! gcs_err=$(GOOGLE_APPLICATION_CREDENTIALS="$WORK/gcs-key.json" \
                   gcloud storage cp "$WORK/probe-gcs" "gs://$GCS_BUCKET/$CHECK" \
                   --quiet 2>&1); then
    die "the GCS key cannot write to gs://$GCS_BUCKET: $(printf '%s' "$gcs_err" | tail -1)"
  fi
  GOOGLE_APPLICATION_CREDENTIALS="$WORK/gcs-key.json" \
    gcloud storage rm "gs://$GCS_BUCKET/$CHECK" --quiet >/dev/null 2>&1 || true
  info "GCS: write and delete ok"

  if [ $WANT_S3 = 1 ]; then
    AK=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["AccessKey"]["AccessKeyId"])' "$WORK/s3-key.json")
    SK=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["AccessKey"]["SecretAccessKey"])' "$WORK/s3-key.json")
    # A real file, not /dev/null: the cli checksums the body and wants something
    # seekable, so a character device fails the upload rather than the
    # credentials -- which then reads as the key being broken when it is fine.
    printf 'tsync ci setup check\n' > "$WORK/probe"
    # A new IAM key is not always usable immediately. The last error is kept and
    # shown, since a verification that hides why it failed sends you looking in
    # the wrong place.
    s3_err=""
    for attempt in 1 2 3 4 5 6 7 8; do
      if s3_err=$(env -u AWS_PROFILE -u AWS_SESSION_TOKEN \
                    AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" \
                    AWS_DEFAULT_REGION="$AWS_REGION" \
                    aws s3api put-object --bucket "$S3_BUCKET" --key "$CHECK" \
                      --body "$WORK/probe" 2>&1); then
        break
      fi
      [ $attempt = 8 ] && die "the S3 key cannot write to s3://$S3_BUCKET: $(printf '%s' "$s3_err" | tail -1)"
      sleep 5
    done
    env -u AWS_PROFILE -u AWS_SESSION_TOKEN \
      AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" \
      AWS_DEFAULT_REGION="$AWS_REGION" \
      aws s3api delete-object --bucket "$S3_BUCKET" --key "$CHECK" >/dev/null 2>&1 || true
    info "S3: write and delete ok"
  fi
fi

# What makes the serverless half testable at all: without a function on the
# bucket, a conformance run can prove a request object lands and nothing more.
DEPLOYED_S3=0
DEPLOYED_GCS=0
if [ "$DEPLOY_FUNCTIONS" = 1 ]; then
  say "Chunk verifier on the CI bucket(s)"

  # The state bucket the real stack already uses, unless told otherwise -- a
  # different prefix in it, never a different one of these.
  if [ -z "$TF_STATE_BUCKET" ] && [ -f terraform/backend.hcl ]; then
    TF_STATE_BUCKET=$(sed -n 's/^ *bucket *= *"\(.*\)"/\1/p' terraform/backend.hcl)
  fi
  [ -n "$TF_STATE_BUCKET" ] \
    || die "no terraform state bucket: set TF_STATE_BUCKET, or run ./terraform/init.sh first"
  info "state gs://$TF_STATE_BUCKET/$TF_STATE_PREFIX (never the deployment's own prefix)"

  TF_ARGS="-var=gcs_bucket=$GCS_BUCKET -var=gcp_project=$GCP_PROJECT"
  TF_ARGS="$TF_ARGS -var=gcp_region=$GCS_LOCATION -var=gcp_function_region=$GCS_LOCATION"
  if [ $WANT_S3 = 1 ]; then
    TF_ARGS="$TF_ARGS -var=s3_bucket=$S3_BUCKET -var=aws_region=$AWS_REGION"
  fi

  run "(cd terraform/ci && $TF init -input=false -reconfigure \
        -backend-config=bucket=$TF_STATE_BUCKET \
        -backend-config=prefix=$TF_STATE_PREFIX >/dev/null)"
  run "(cd terraform/ci && $TF apply -input=false -auto-approve $TF_ARGS >/dev/null)"

  if [ $DRY_RUN = 0 ]; then
    # Read back rather than assumed: an apply that half succeeded would
    # otherwise have CI told the function is there and every run fail on a
    # timeout, which reads as the function being broken rather than absent.
    out=$(cd terraform/ci && $TF output -json 2>/dev/null || echo '{}')
    getout() { printf '%s' "$out" | python3 -c \
      'import json,sys;d=json.load(sys.stdin);v=d.get(sys.argv[1],{}).get("value");print(v if v else "")' "$1"; }
    [ -n "$(getout gcs_verify_function)" ] && DEPLOYED_GCS=1
    [ -n "$(getout s3_verify_function)" ] && DEPLOYED_S3=1
    info "gcs verifier: $([ $DEPLOYED_GCS = 1 ] && echo deployed || echo 'not deployed')"
    info "s3 verifier:  $([ $DEPLOYED_S3 = 1 ] && echo deployed || echo 'not deployed')"
  fi
fi

say "GitHub secrets on $REPO"
if [ $DRY_RUN = 1 ]; then
  info "+ gh secret set TSYNC_CI_GCS_BUCKET / TSYNC_CI_GCS_SERVICE_ACCOUNT_KEY"
  [ $WANT_S3 = 1 ] && info "+ gh secret set TSYNC_CI_S3_{BUCKET,REGION,ACCESS_KEY_ID,SECRET_ACCESS_KEY}"
else
  gh secret set TSYNC_CI_GCS_BUCKET -R "$REPO" --body "$GCS_BUCKET"
  gh secret set TSYNC_CI_GCS_SERVICE_ACCOUNT_KEY -R "$REPO" < "$WORK/gcs-key.json"
  info "TSYNC_CI_GCS_BUCKET, TSYNC_CI_GCS_SERVICE_ACCOUNT_KEY"
  # Set from what the apply actually reported, and cleared when it reported
  # nothing: a run that finds this set and the function absent fails on a
  # timeout, which is the one failure that looks like a code fault and is not.
  if [ $DEPLOYED_GCS = 1 ]; then
    gh secret set TSYNC_CI_GCS_VERIFY_FUNCTION -R "$REPO" --body "tsync-verify-ci"
    gh secret set TSYNC_CI_GCS_FUNCTION_REGION -R "$REPO" --body "$GCS_LOCATION"
    info "TSYNC_CI_GCS_VERIFY_FUNCTION, TSYNC_CI_GCS_FUNCTION_REGION"
  else
    gh secret delete TSYNC_CI_GCS_VERIFY_FUNCTION -R "$REPO" >/dev/null 2>&1 || true
    info "no gcs verifier deployed -- conformance will report that half not run"
  fi
  if [ $WANT_S3 = 1 ]; then
    gh secret set TSYNC_CI_S3_BUCKET -R "$REPO" --body "$S3_BUCKET"
    gh secret set TSYNC_CI_S3_REGION -R "$REPO" --body "$AWS_REGION"
    gh secret set TSYNC_CI_S3_ACCESS_KEY_ID -R "$REPO" --body "$AK"
    gh secret set TSYNC_CI_S3_SECRET_ACCESS_KEY -R "$REPO" --body "$SK"
    info "TSYNC_CI_S3_BUCKET, _REGION, _ACCESS_KEY_ID, _SECRET_ACCESS_KEY"
    if [ $DEPLOYED_S3 = 1 ]; then
      gh secret set TSYNC_CI_S3_VERIFY_FUNCTION -R "$REPO" --body "tsync-verify-ci"
      info "TSYNC_CI_S3_VERIFY_FUNCTION"
    else
      gh secret delete TSYNC_CI_S3_VERIFY_FUNCTION -R "$REPO" >/dev/null 2>&1 || true
      info "no s3 verifier deployed -- conformance will report that half not run"
    fi
  fi
fi

# Only now: the new credentials are proven and GitHub holds them, so anything
# older is safe to revoke. Doing this earlier is what would leave CI holding a
# dead key if a later step failed.
if [ $DRY_RUN = 0 ]; then
  say "Revoking superseded keys"
  for k in ${GCS_KEYS_BEFORE:-}; do
    gcloud iam service-accounts keys delete "$k" --iam-account "$GCS_SA_EMAIL" \
      --project "$GCP_PROJECT" --quiet >/dev/null 2>&1 || true
  done
  info "GCS: revoked $(printf '%s\n' ${GCS_KEYS_BEFORE:-} | grep -c . || true) older key(s)"
  if [ $WANT_S3 = 1 ]; then
    for k in ${S3_KEYS_BEFORE:-}; do
      aws iam delete-access-key --user-name "$AWS_IAM_USER" --access-key-id "$k" >/dev/null 2>&1 || true
    done
    info "S3: revoked $(printf '%s\n' ${S3_KEYS_BEFORE:-} | grep -c . || true) older key(s)"
  fi
fi

say "Done"
info "The workflows will read exactly these names:"
info "  TSYNC_CI_GCS_BUCKET"
info "  TSYNC_CI_GCS_SERVICE_ACCOUNT_KEY"
if [ $WANT_S3 = 1 ]; then
  info "  TSYNC_CI_S3_BUCKET"
  info "  TSYNC_CI_S3_REGION"
  info "  TSYNC_CI_S3_ACCESS_KEY_ID"
  info "  TSYNC_CI_S3_SECRET_ACCESS_KEY"
  [ $DEPLOYED_S3 = 1 ] && info "  TSYNC_CI_S3_VERIFY_FUNCTION"
else
  info "  (no S3 secrets -- set up the aws cli and re-run to add them)"
fi
printf '\n'
info "No secret value was printed; the key files lived only in $WORK, now gone."
info "Forks get no secrets, so the jobs reading these must skip cleanly there."
