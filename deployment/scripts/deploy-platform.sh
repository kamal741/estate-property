#!/usr/bin/env bash
# One-shot: optional GCS state bootstrap, terraform init/apply, kubeconfig sync, Helm (Jenkins + ingress).
#
# Usage (from repo root):
#   ./deployment/scripts/deploy-platform.sh <dev|prod> [terraform_state_bucket] [gcs_bucket_location]
#
# Examples:
#   ./deployment/scripts/deploy-platform.sh dev
#   ./deployment/scripts/deploy-platform.sh dev my-unique-tf-state-bucket us-central1
#   HELM_ONLY=1 ./deployment/scripts/deploy-platform.sh dev    # only Jenkins + platform-ingress Helm
#
# Environment:
#   HELM_ONLY=1               Only run Helm (Jenkins + platform-ingress). Skips gcloud bootstrap, terraform,
#                             and kubeconfig sync — your kubecontext must already target the right cluster.
#   SKIP_TERRAFORM=1          Skip terraform apply only (still runs bootstrap, init, kube sync, then Helm).
#   SKIP_KUBECONFIG_SYNC=1    Skip terraform output get-credentials (use with SKIP_TERRAFORM=1 if kubeconfig OK).
#   SKIP_GCLOUD_BOOTSTRAP=1   Skip gcloud API enable + state bucket create (use when bucket already exists).
#   TERRAFORM_STATE_BUCKET    State bucket name (default: estateflow-bucket-<env> — must be globally unique in GCS).
#   GCS_STATE_BUCKET_LOCATION Location for new bucket (default: region from terraform.tfvars, else us-central1).
#   BUILD_PUSH_JENKINS_IMAGE=1  After kube sync, build and push Jenkins to Artifact Registry before Helm (needs Docker).
#   ARTIFACT_REGISTRY_REPOSITORY  Required when BUILD_PUSH_JENKINS_IMAGE=1 (e.g. estateflow-dev). When set (with full
#                             deploy path), also exports JENKINS_IMAGE_REPOSITORY for Helm so jenkins-values need no project id.
#   JENKINS_IMAGE_TAG          Optional; defaults to <env> (dev or prod) to match k8s/env/<env>/jenkins-values.yaml tags.
#   JENKINS_IMAGE_REPOSITORY   Optional full image path without tag; if unset, deploy.sh may fill from Terraform output.
#   SKIP_JENKINS_IMAGE_REPOSITORY_AUTO=1  Do not auto-set JENKINS_IMAGE_REPOSITORY from ARTIFACT_REGISTRY_REPOSITORY / TF.
#   GCP_PROJECT_ID / GCP_REGION  If terraform.tfvars is missing and both are set, create that file (gitignored).
#   REQUIRE_MANUAL_TFVARS=1    If terraform.tfvars is missing, do not auto-create from gcloud; require a manual file
#                             or GCP_PROJECT_ID+GCP_REGION.
#   TERRAFORM_INIT_EXTRA       Extra args to terraform init (e.g. -reconfigure).
#   TERRAFORM_APPLY_EXTRA      Extra args to terraform apply (e.g. -target=...).
#
# --- Command combinations (repo root; dev examples; use prod where needed) -----------------
#
#   # 1) Default state bucket estateflow-bucket-dev; if terraform.tfvars is missing, it is created from gcloud
#   #    active project + region (GCP_REGION or compute/region or us-central1). Opt out: REQUIRE_MANUAL_TFVARS=1
#   ./deployment/scripts/deploy-platform.sh dev
#
#   # 2) Explicit Terraform remote state bucket + bucket location (2nd and 3rd args)
#   ./deployment/scripts/deploy-platform.sh dev dev-estateflow-bucket us-central1
#
#   # 2b) Override state bucket / location via env (wins over positional args when set — see STATE_BUCKET= in script)
#   TERRAFORM_STATE_BUCKET=my-tf-state GCS_STATE_BUCKET_LOCATION=us-east1 ./deployment/scripts/deploy-platform.sh dev
#
#   # 3) Force manual terraform.tfvars (do not auto-create from gcloud)
#   REQUIRE_MANUAL_TFVARS=1 ./deployment/scripts/deploy-platform.sh dev
#
#   # 3b) Explicit project/region when tfvars is missing (no gcloud required)
#   GCP_PROJECT_ID=my-proj GCP_REGION=us-central1 ./deployment/scripts/deploy-platform.sh dev dev-estateflow-bucket us-central1
#   # 4) Helm only (kubecontext must already target the cluster; no terraform.tfvars required)
#   HELM_ONLY=1 ./deployment/scripts/deploy-platform.sh dev
#
#   # 5) Skip Terraform apply (still bootstrap if not skipped, init, kube sync, Helm)
#   SKIP_TERRAFORM=1 ./deployment/scripts/deploy-platform.sh dev
#
#   # 6) Skip apply + skip kubeconfig refresh (kubectl already correct)
#   SKIP_TERRAFORM=1 SKIP_KUBECONFIG_SYNC=1 ./deployment/scripts/deploy-platform.sh dev
#
#   # 7) State bucket already exists — skip API enable + bucket create
#   SKIP_GCLOUD_BOOTSTRAP=1 ./deployment/scripts/deploy-platform.sh dev dev-estateflow-bucket us-central1
#
#   # 8) Build/push Jenkins image to Artifact Registry, then Helm (needs Docker; AR repo must exist)
#   ARTIFACT_REGISTRY_REPOSITORY=estateflow-dev BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-platform.sh dev
#
#   # 9) Push with custom controller tag (defaults to env name dev/prod)
#   ARTIFACT_REGISTRY_REPOSITORY=estateflow-dev BUILD_PUSH_JENKINS_IMAGE=1 JENKINS_IMAGE_TAG=v1.0.0 \
#     ./deployment/scripts/deploy-platform.sh dev
#
#   # 10) Do not auto-export JENKINS_IMAGE_REPOSITORY for Helm (use values/chart only)
#   SKIP_JENKINS_IMAGE_REPOSITORY_AUTO=1 ./deployment/scripts/deploy-platform.sh dev
#
#   # 11) Terraform init after backend change
#   TERRAFORM_INIT_EXTRA=-reconfigure ./deployment/scripts/deploy-platform.sh dev dev-estateflow-bucket us-central1
#
# --------------------------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  die "usage: $0 <dev|prod> [terraform_state_bucket] [gcs_bucket_location]
  HELM_ONLY=1 $0 <env>  — only Helm (Jenkins + platform-ingress); no Terraform.
  Otherwise needs deployment/terraform/envs/<env>/terraform.tfvars (copy from .example), or
  GCP_PROJECT_ID+GCP_REGION, or gcloud on PATH with a configured project (auto-writes tfvars when missing)."
}

[[ "${1:-}" ]] || usage

ENV="$1"
TF_DIR="$REPO_ROOT/deployment/terraform/envs/$ENV"
K8S_HELM="$REPO_ROOT/k8s/scripts/deploy.sh"
TFVARS="$TF_DIR/terraform.tfvars"

[[ -d "$TF_DIR" ]] || die "missing terraform env: $TF_DIR"
[[ -f "$K8S_HELM" ]] || die "missing k8s/scripts/deploy.sh"

helm_only() {
  echo "==> HELM_ONLY=1 — Helm only (Jenkins + platform-ingress); kubecontext must already target the cluster"
  bash "$K8S_HELM" helm "$ENV" jenkins
  bash "$K8S_HELM" helm "$ENV" platform-ingress
  echo "==> done."
}

if [[ "${HELM_ONLY:-}" == "1" ]]; then
  helm_only
  exit 0
fi

DOCKER_BUILD_PUSH="$REPO_ROOT/k8s/scripts/docker-build-push-gcp-ar.sh"
[[ -f "$DOCKER_BUILD_PUSH" ]] || die "missing k8s/scripts/docker-build-push-gcp-ar.sh"

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

  die "missing $TFVARS

  Create it from the example (gitignored — never committed), then set real project_id and region:
    cp \"$TF_DIR/terraform.tfvars.example\" \"$TFVARS\"
    nano \"$TFVARS\"

  Or set project and region explicitly:
    GCP_PROJECT_ID=\"\$(gcloud config get-value project)\" GCP_REGION=us-central1 ./deployment/scripts/deploy-platform.sh $ENV

  Or install/configure gcloud so \`gcloud config get-value project\` returns your project (then re-run without tfvars)."
}

ensure_tfvars

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
  gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com artifactregistry.googleapis.com --project="$PROJECT_ID"

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

if [[ "${SKIP_KUBECONFIG_SYNC:-}" != "1" ]]; then
  sync_kube
else
  echo "==> SKIP_KUBECONFIG_SYNC=1 — skipping kubeconfig refresh"
fi

build_push_jenkins_if_requested() {
  [[ "${BUILD_PUSH_JENKINS_IMAGE:-}" == "1" ]] || return 0
  [[ -n "${ARTIFACT_REGISTRY_REPOSITORY:-}" ]] ||
    die "ARTIFACT_REGISTRY_REPOSITORY is required when BUILD_PUSH_JENKINS_IMAGE=1 (Artifact Registry repository id, e.g. estateflow)"
  local jtag="${JENKINS_IMAGE_TAG:-$ENV}"
  echo "==> BUILD_PUSH_JENKINS_IMAGE=1 — build and push Jenkins (${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REGISTRY_REPOSITORY}/jenkins:${jtag})"
  bash "$DOCKER_BUILD_PUSH" \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    --repository "$ARTIFACT_REGISTRY_REPOSITORY" \
    --image jenkins \
    --tag "$jtag" \
    --dockerfile jenkins/Dockerfile
}

build_push_jenkins_if_requested

if [[ "${SKIP_JENKINS_IMAGE_REPOSITORY_AUTO:-}" != "1" && -z "${JENKINS_IMAGE_REPOSITORY:-}" && -n "${ARTIFACT_REGISTRY_REPOSITORY:-}" ]]; then
  export JENKINS_IMAGE_REPOSITORY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REGISTRY_REPOSITORY}/jenkins"
  echo "==> JENKINS_IMAGE_REPOSITORY=$JENKINS_IMAGE_REPOSITORY (from project/region + ARTIFACT_REGISTRY_REPOSITORY)"
fi

echo "==> Helm: Jenkins then platform-ingress"
bash "$K8S_HELM" helm "$ENV" jenkins
bash "$K8S_HELM" helm "$ENV" platform-ingress

echo "==> done. For Jenkins pipelines (cluster / namespaces / gcloud command from Terraform):"
echo "    $REPO_ROOT/k8s/scripts/jenkins-gke-env-from-terraform.sh $ENV --export"
