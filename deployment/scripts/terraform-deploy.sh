#!/usr/bin/env bash
# Terraform + GCS state bootstrap + kubeconfig sync only (no Helm, no Jenkins image build).
#
# Usage (from repo root):
#   ./deployment/scripts/terraform-deploy.sh <dev|prod> [terraform_state_bucket] [gcs_bucket_location]
#
# Environment: same as deploy-platform.sh for Terraform (SKIP_TERRAFORM, SKIP_KUBECONFIG_SYNC, SKIP_GCLOUD_BOOTSTRAP,
# TERRAFORM_STATE_BUCKET, GCS_STATE_BUCKET_LOCATION, TERRAFORM_INIT_EXTRA, TERRAFORM_APPLY_EXTRA, GCP_PROJECT_ID,
# GCP_REGION, REQUIRE_MANUAL_TFVARS).
#
# Command combinations (repo root; replace bucket/region if you use non-defaults):
#   ./deployment/scripts/terraform-deploy.sh dev
#   ./deployment/scripts/terraform-deploy.sh dev my-unique-state-bucket us-central1
#   Default state bucket: <project_id>-tfstate-<env> (GCS names are global; avoids estateflow-bucket-<env> collisions).
#   If you already use legacy gs://estateflow-bucket-<env>, pass it as arg 2 or set TERRAFORM_STATE_BUCKET.
#   SKIP_TERRAFORM=1 ./deployment/scripts/terraform-deploy.sh dev
#       # init + kube sync only (no apply); use after manual plan/apply elsewhere
#   SKIP_KUBECONFIG_SYNC=1 ./deployment/scripts/terraform-deploy.sh dev
#       # apply without refreshing gcloud get-credentials
#   SKIP_GCLOUD_BOOTSTRAP=1 ./deployment/scripts/terraform-deploy.sh dev
#       # skip gcloud services enable + state bucket create (bucket/APIs must exist)
#   SKIP_TERRAFORM=1 SKIP_KUBECONFIG_SYNC=1 ./deployment/scripts/terraform-deploy.sh dev
#       # terraform init only (no apply, no kube sync)
#   TERRAFORM_APPLY_EXTRA="-target=module.infra.google_container_cluster.cluster" ./deployment/scripts/terraform-deploy.sh dev
#       # example: targeted apply (escape quotes if you add more)
#   ./deployment/scripts/terraform-deploy.sh dev && \
#     ARTIFACT_REGISTRY_REPOSITORY=estateflow-dev BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-k8s-jenkins.sh dev
#       # infra then Jenkins (Cloud Build + Helm); align jenkins-values image.tag with JENKINS_IMAGE_TAG if needed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  die "usage: $0 <dev|prod> [terraform_state_bucket] [gcs_bucket_location]
  Runs gcloud bootstrap (optional), terraform init/apply (optional), kubeconfig sync (optional).
  For Jenkins + ingress use ./deployment/scripts/deploy-k8s-jenkins.sh or ./deployment/scripts/deploy-platform.sh"
}

[[ "${1:-}" ]] || usage

ENV="$1"
TF_DIR="$REPO_ROOT/deployment/terraform/envs/$ENV"
TFVARS="$TF_DIR/terraform.tfvars"

[[ -d "$TF_DIR" ]] || die "missing terraform env: $TF_DIR"

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

ensure_tfvars() {
  [[ -f "$TFVARS" ]] && return 0

  if [[ -n "${GCP_PROJECT_ID:-}" && -n "${GCP_REGION:-}" ]]; then
    printf 'project_id = "%s"\nregion     = "%s"\n' "${GCP_PROJECT_ID}" "${GCP_REGION}" >"$TFVARS"
    echo "==> created $TFVARS from GCP_PROJECT_ID and GCP_REGION (gitignored)"
    return 0
  fi

  if [[ "${REQUIRE_MANUAL_TFVARS:-}" == "1" ]]; then
    :
  elif command -v gcloud >/dev/null 2>&1; then
    local pid reg
    pid="$(gcloud config get-value project 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "$pid" && "$pid" != "(unset)" ]]; then
      reg="${GCP_REGION:-}"
      if [[ -z "$reg" ]]; then
        reg="$(gcloud config get-value compute/region 2>/dev/null | tr -d '\r\n' || true)"
      fi
      if [[ -z "$reg" || "$reg" == "(unset)" ]]; then
        reg=us-central1
      fi
      printf 'project_id = "%s"\nregion     = "%s"\n' "$pid" "$reg" >"$TFVARS"
      echo "==> created $TFVARS from gcloud (project=$pid region=$reg; override with GCP_REGION or edit file)"
      return 0
    fi
  fi

  die "missing $TFVARS — copy from $TF_DIR/terraform.tfvars.example or set GCP_PROJECT_ID+GCP_REGION (see deploy-platform.sh header)."
}

ensure_tfvars

PROJECT_ID="$(tfvar_get project_id)" || die "could not read project_id from $TFVARS"
REGION="$(tfvar_get region)" || die "could not read region from $TFVARS"
[[ -n "$PROJECT_ID" ]] || die "project_id is empty in $TFVARS"
[[ -n "$REGION" ]] || die "region is empty in $TFVARS"

STATE_BUCKET="${TERRAFORM_STATE_BUCKET:-${2:-}}"
STATE_LOCATION="${GCS_STATE_BUCKET_LOCATION:-${3:-}}"
# GCS bucket names are global; project_id in the default avoids 409 on create when a short name is taken elsewhere.
[[ -n "$STATE_BUCKET" ]] || STATE_BUCKET="${PROJECT_ID}-tfstate-${ENV}"
[[ -n "$STATE_LOCATION" ]] || STATE_LOCATION="$REGION"

gcloud_bootstrap() {
  echo "==> gcloud bootstrap (project=$PROJECT_ID, state bucket=$STATE_BUCKET, location=$STATE_LOCATION)"
  gcloud config set project "$PROJECT_ID" >/dev/null

  echo "==> gcloud services enable (idempotent)"
  gcloud services enable \
    cloudresourcemanager.googleapis.com \
    serviceusage.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    --project="$PROJECT_ID"

  if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="$PROJECT_ID" &>/dev/null; then
    echo "==> GCS state bucket already exists in project: gs://${STATE_BUCKET}"
  else
    echo "==> gcloud storage buckets create gs://${STATE_BUCKET}"
    if ! gcloud storage buckets create "gs://${STATE_BUCKET}" \
      --project="$PROJECT_ID" \
      --location="$STATE_LOCATION" \
      --uniform-bucket-level-access; then
      echo "error: could not create gs://${STATE_BUCKET} (name may be in use globally, or IAM/org policy blocked create)." >&2
      echo "  Try another name: pass arg 2 or set TERRAFORM_STATE_BUCKET (suggested: ${PROJECT_ID}-tfstate-${ENV})." >&2
      exit 1
    fi
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

if [[ "${SKIP_KUBECONFIG_SYNC:-}" != "1" ]]; then
  sync_kube
else
  echo "==> SKIP_KUBECONFIG_SYNC=1 — skipping kubeconfig refresh"
fi

echo "==> terraform-deploy done ($ENV). Next: ./deployment/scripts/deploy-k8s-jenkins.sh $ENV"
