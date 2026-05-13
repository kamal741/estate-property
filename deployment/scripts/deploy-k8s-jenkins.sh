#!/usr/bin/env bash
# Jenkins image (Cloud Build → Artifact Registry by default) + Helm: Jenkins + platform-ingress.
# Does not run Terraform. kubecontext must target the cluster (run terraform-deploy.sh first or get-credentials).
#
# Usage (from repo root):
#   ./deployment/scripts/deploy-k8s-jenkins.sh <dev|prod>
#
# Environment:
#   BUILD_PUSH_JENKINS_IMAGE=1   Build and push Jenkins before Helm (default: unset = Helm only).
#   ARTIFACT_REGISTRY_REPOSITORY Required when BUILD_PUSH_JENKINS_IMAGE=1 (e.g. estateflow-dev).
#   JENKINS_IMAGE_TAG             Image tag (default: <env> dev|prod).
#   JENKINS_BUILD_WITH_DOCKER=1 Use local docker + k8s/scripts/docker-build-push-gcp-ar.sh instead of Cloud Build.
#   SKIP_JENKINS_IMAGE_REPOSITORY_AUTO=1  Do not export JENKINS_IMAGE_REPOSITORY for Helm.
#   JENKINS_IMAGE_REPOSITORY     Full image path without tag (optional override).
#   GCP_PROJECT_ID / GCP_REGION  If terraform.tfvars is missing, same auto-create rules as terraform-deploy.sh.
#   REQUIRE_MANUAL_TFVARS=1      Do not auto-create tfvars from gcloud.
#
# Command combinations (repo root; kubectl must already target the GKE cluster unless you run terraform-deploy first):
#   ./deployment/scripts/deploy-k8s-jenkins.sh dev
#       # Helm only: Jenkins + platform-ingress (uses values / terraform output for image repo as implemented in deploy.sh)
#   ARTIFACT_REGISTRY_REPOSITORY=estateflow-dev BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-k8s-jenkins.sh dev
#       # gcloud builds submit (jenkins/cloudbuild.yaml) then Helm
#   JENKINS_IMAGE_TAG=v1.0.0 ARTIFACT_REGISTRY_REPOSITORY=estateflow-dev BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-k8s-jenkins.sh dev
#       # push tagged image; deploy.sh passes JENKINS_IMAGE_TAG to Helm (--set-string image.tag)
#   JENKINS_BUILD_WITH_DOCKER=1 ARTIFACT_REGISTRY_REPOSITORY=estateflow-dev BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-k8s-jenkins.sh prod
#       # local Docker build + push via k8s/scripts/docker-build-push-gcp-ar.sh then Helm
#   REPO="$(cd deployment/terraform/envs/dev && terraform output -raw artifact_registry_repository_id)" && \
#     ARTIFACT_REGISTRY_REPOSITORY="$REPO" BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-k8s-jenkins.sh dev
#       # AR repo id from Terraform state (run from repo root after apply)
#   ./deployment/scripts/terraform-deploy.sh dev && \
#     ARTIFACT_REGISTRY_REPOSITORY=estateflow-dev BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-k8s-jenkins.sh dev
#       # full split flow equivalent to ./deployment/scripts/deploy-platform.sh dev (without extra bucket args)
#   HELM_ONLY=1 ARTIFACT_REGISTRY_REPOSITORY=estateflow-dev BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-platform.sh dev
#       # wrapper: only this script + optional build (same as direct deploy-k8s-jenkins.sh with those env vars)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
K8S_HELM="$REPO_ROOT/k8s/scripts/deploy.sh"
DOCKER_BUILD_PUSH="$REPO_ROOT/k8s/scripts/docker-build-push-gcp-ar.sh"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  die "usage: $0 <dev|prod>
  Optional: BUILD_PUSH_JENKINS_IMAGE=1 ARTIFACT_REGISTRY_REPOSITORY=... (Cloud Build to AR unless JENKINS_BUILD_WITH_DOCKER=1).
  Needs deployment/terraform/envs/<env>/terraform.tfvars (or GCP_PROJECT_ID+GCP_REGION / gcloud)."
}

[[ "${1:-}" ]] || usage

ENV="$1"
TF_DIR="$REPO_ROOT/deployment/terraform/envs/$ENV"
TFVARS="$TF_DIR/terraform.tfvars"

[[ -d "$TF_DIR" ]] || die "missing terraform env: $TF_DIR"
[[ -f "$K8S_HELM" ]] || die "missing k8s/scripts/deploy.sh"

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
      echo "==> created $TFVARS from gcloud (project=$pid region=$reg)"
      return 0
    fi
  fi

  die "missing $TFVARS — copy from $TF_DIR/terraform.tfvars.example or set GCP_PROJECT_ID+GCP_REGION"
}

ensure_tfvars

PROJECT_ID="$(tfvar_get project_id)" || die "could not read project_id from $TFVARS"
REGION="$(tfvar_get region)" || die "could not read region from $TFVARS"
[[ -n "$PROJECT_ID" ]] || die "project_id is empty in $TFVARS"
[[ -n "$REGION" ]] || die "region is empty in $TFVARS"

build_push_jenkins_cloud() {
  [[ -n "${ARTIFACT_REGISTRY_REPOSITORY:-}" ]] ||
    die "ARTIFACT_REGISTRY_REPOSITORY is required when BUILD_PUSH_JENKINS_IMAGE=1"
  command -v gcloud >/dev/null 2>&1 || die "gcloud is required for Cloud Build"
  [[ -f "$REPO_ROOT/jenkins/cloudbuild.yaml" ]] || die "missing jenkins/cloudbuild.yaml"

  jtag="${JENKINS_IMAGE_TAG:-$ENV}"
  full_image="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REGISTRY_REPOSITORY}/jenkins:${jtag}"

  if [[ "${JENKINS_BUILD_WITH_DOCKER:-}" == "1" ]]; then
    [[ -f "$DOCKER_BUILD_PUSH" ]] || die "missing k8s/scripts/docker-build-push-gcp-ar.sh"
    echo "==> BUILD_PUSH_JENKINS_IMAGE=1 (local Docker) → $full_image"
    bash "$DOCKER_BUILD_PUSH" \
      --project "$PROJECT_ID" \
      --region "$REGION" \
      --repository "$ARTIFACT_REGISTRY_REPOSITORY" \
      --image jenkins \
      --tag "$jtag" \
      --dockerfile jenkins/Dockerfile
    return 0
  fi

  echo "==> BUILD_PUSH_JENKINS_IMAGE=1 (gcloud builds submit / Cloud Build) → $full_image"
  pushd "$REPO_ROOT" >/dev/null || exit 1
  gcloud builds submit . \
    --config=jenkins/cloudbuild.yaml \
    --substitutions="_AR_IMAGE=${full_image}" \
    --project="$PROJECT_ID"
  popd >/dev/null || true
}

if [[ "${BUILD_PUSH_JENKINS_IMAGE:-}" == "1" ]]; then
  build_push_jenkins_cloud
fi

if [[ "${SKIP_JENKINS_IMAGE_REPOSITORY_AUTO:-}" != "1" && -z "${JENKINS_IMAGE_REPOSITORY:-}" && -n "${ARTIFACT_REGISTRY_REPOSITORY:-}" ]]; then
  export JENKINS_IMAGE_REPOSITORY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REGISTRY_REPOSITORY}/jenkins"
  echo "==> JENKINS_IMAGE_REPOSITORY=$JENKINS_IMAGE_REPOSITORY (set for Helm; pass JENKINS_IMAGE_TAG to override values image.tag)"
fi

echo "==> Helm: Jenkins then platform-ingress"
bash "$K8S_HELM" helm "$ENV" jenkins
bash "$K8S_HELM" helm "$ENV" platform-ingress

echo "==> deploy-k8s-jenkins done ($ENV). Terraform context: $REPO_ROOT/k8s/scripts/jenkins-gke-env-from-terraform.sh $ENV --export"
