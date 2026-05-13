#!/usr/bin/env bash
# One-shot: optional GCS state bootstrap, terraform init/apply, kubeconfig sync, Helm (Jenkins + ingress).
#
# Usage (from repo root):
#   ./deployment/scripts/deploy-platform.sh <dev|prod> [terraform_state_bucket] [gcs_bucket_location]
#
# Examples:
#   ./deployment/scripts/deploy-platform.sh dev
#   ./deployment/scripts/deploy-platform.sh dev my-unique-tf-state-bucket us-central1
#
# Environment:
#   SKIP_TERRAFORM=1          Skip terraform apply (still runs init + kube sync + Helm unless skipped below).
#   SKIP_GCLOUD_BOOTSTRAP=1   Skip gcloud API enable + state bucket create (use when bucket already exists).
#   TERRAFORM_STATE_BUCKET    State bucket name (default: estateflow-bucket-<env> — must be globally unique in GCS).
#   GCS_STATE_BUCKET_LOCATION Location for new bucket (default: region from terraform.tfvars, else us-central1).
#   TERRAFORM_APPLY_EXTRA     Extra args for terraform apply (e.g. -target=...)
#   TERRAFORM_INIT_EXTRA      Extra args for terraform init (e.g. -migrate-state)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  die "usage: $0 <dev|prod> [terraform_state_bucket] [gcs_bucket_location]
  Second arg overrides TERRAFORM_STATE_BUCKET; third overrides GCS_STATE_BUCKET_LOCATION.
  Requires: terraform.tfvars in deployment/terraform/envs/<env>/ with project_id and region."
}

[[ "${1:-}" ]] || usage

ENV="$1"
TF_DIR="$REPO_ROOT/deployment/terraform/envs/$ENV"
K8S_HELM="$REPO_ROOT/k8s/scripts/deploy.sh"
TFVARS="$TF_DIR/terraform.tfvars"

[[ -d "$TF_DIR" ]] || die "missing terraform env: $TF_DIR"
[[ -f "$K8S_HELM" ]] || die "missing k8s/scripts/deploy.sh"
[[ -f "$TFVARS" ]] || die "missing $TFVARS — copy from terraform.tfvars.example and set project_id and region"

# Read first assignment of key = "value" or key = value from HCL-ish tfvars (no nested blocks).
tfvar_get() {
  local key="$1" line val
  line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS" | head -1) || return 1
  val="${line#*=}"
  val="${val%%#*}"
  val="${val//\"/}"
  val="${val//\'}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

PROJECT_ID="$(tfvar_get project_id)" || die "could not read project_id from $TFVARS"
REGION="$(tfvar_get region)" || die "could not read region from $TFVARS"
[[ -n "$PROJECT_ID" ]] || die "project_id is empty in $TFVARS"
[[ -n "$REGION" ]] || die "region is empty in $TFVARS"

STATE_BUCKET="${TERRAFORM_STATE_BUCKET:-${2:-}}"
STATE_LOCATION="${GCS_STATE_BUCKET_LOCATION:-${3:-}}"
[[ -n "$STATE_BUCKET" ]] || STATE_BUCKET="estateflow-bucket-${ENV}"
[[ -n "$STATE_LOCATION" ]] || STATE_LOCATION="$REGION"

gcloud_bootstrap() {
  echo "==> gcloud bootstrap (project=$PROJECT_ID, state bucket=$STATE_BUCKET, location=$STATE_LOCATION)"
  gcloud config set project "$PROJECT_ID" >/dev/null

  echo "==> gcloud services enable (idempotent)"
  gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com --project="$PROJECT_ID"

  if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="$PROJECT_ID" &>/dev/null; then
    echo "==> GCS state bucket already exists: gs://${STATE_BUCKET}"
  else
    echo "==> gcloud storage buckets create gs://${STATE_BUCKET}"
    gcloud storage buckets create "gs://${STATE_BUCKET}" \
      --project="$PROJECT_ID" \
      --location="$STATE_LOCATION" \
      --uniform-bucket-level-access
  fi
}

tf_init() {
  pushd "$TF_DIR" >/dev/null || exit 1
  echo "==> terraform init ($ENV) backend bucket=$STATE_BUCKET"
  # shellcheck disable=SC2086
  terraform init -input=false \
    -backend-config="bucket=${STATE_BUCKET}" \
    ${TERRAFORM_INIT_EXTRA:-}
  popd >/dev/null || true
}

tf_apply() {
  pushd "$TF_DIR" >/dev/null || exit 1
  echo "==> terraform apply ($ENV)"
  # shellcheck disable=SC2086
  terraform apply -auto-approve ${TERRAFORM_APPLY_EXTRA:-}
  popd >/dev/null || true
}

sync_kube() {
  pushd "$TF_DIR" >/dev/null || exit 1
  local cmd
  cmd="$(terraform output -raw gke_get_credentials_command)"
  echo "==> kubeconfig: $cmd"
  eval "$cmd"
  popd >/dev/null || true
}

if [[ "${SKIP_GCLOUD_BOOTSTRAP:-}" != "1" ]]; then
  gcloud_bootstrap
else
  echo "==> SKIP_GCLOUD_BOOTSTRAP=1 — skipping gcloud API enable and bucket create"
fi

tf_init

if [[ "${SKIP_TERRAFORM:-}" != "1" ]]; then
  tf_apply
else
  echo "==> SKIP_TERRAFORM=1 — skipping terraform apply"
fi

sync_kube

echo "==> Helm: Jenkins then platform-ingress"
bash "$K8S_HELM" helm "$ENV" jenkins
bash "$K8S_HELM" helm "$ENV" platform-ingress

echo "==> done. For Jenkins pipelines (cluster / namespaces / gcloud command from Terraform):"
echo "    $REPO_ROOT/k8s/scripts/jenkins-gke-env-from-terraform.sh $ENV --export"
