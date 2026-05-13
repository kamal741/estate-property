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
#   SKIP_JENKINS_WAIT=1          After Helm, do not wait for the Deployment or print Jenkins pod logs.
#   JENKINS_WAIT_STRICT=1        If rollout or logs fails, exit non-zero (default: best-effort — skip/warn when
#                                kubectl is missing, cluster unreachable, or rollout errors — for local laptops).
#   JENKINS_ROLLOUT_TIMEOUT       kubectl rollout timeout (default 600s).
#   JENKINS_LOG_TAIL              Lines of logs to print after rollout (default 200).
#   JENKINS_LOGS_FOLLOW=1         After rollout, stream logs with kubectl -f (Ctrl+C to stop).
#   RELEASE                      Helm release name (default jenkins); must match for label app.kubernetes.io/instance.
#   KUBE_REQUEST_TIMEOUT         Short timeout for kubectl discovery (default 10s).
#
# Command combinations (repo root; Helm needs a valid kubeconfig for the target cluster):
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
#   JENKINS_WAIT_STRICT=1 ./deployment/scripts/deploy-k8s-jenkins.sh dev
#       # fail the script if rollout/logs cannot run or rollout does not succeed
#   SKIP_JENKINS_WAIT=1 ./deployment/scripts/deploy-k8s-jenkins.sh dev
#       # Helm only; no kubectl rollout / logs

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

jenkins_target_namespace() {
  if [[ -n "${NAMESPACE:-}" ]]; then
    printf '%s' "${NAMESPACE}"
    return 0
  fi
  if [[ -n "${JENKINS_HELM_NAMESPACE:-}" ]]; then
    printf '%s' "${JENKINS_HELM_NAMESPACE}"
    return 0
  fi
  if command -v terraform >/dev/null 2>&1; then
    local out
    out="$(cd "$TF_DIR" && terraform output -raw gke_namespace 2>/dev/null)" || true
    if [[ -n "$out" ]]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  printf '%s-estateflow' "$ENV"
}

wait_for_jenkins_and_logs() {
  [[ "${SKIP_JENKINS_WAIT:-}" == "1" ]] && return 0

  local strict=0
  [[ "${JENKINS_WAIT_STRICT:-}" == "1" ]] && strict=1
  local req="${KUBE_REQUEST_TIMEOUT:-10s}"

  if ! command -v kubectl >/dev/null 2>&1; then
    if [[ "$strict" == "1" ]]; then
      die "kubectl is required when JENKINS_WAIT_STRICT=1 (or set SKIP_JENKINS_WAIT=1)"
    fi
    echo "==> Skipping Jenkins wait/logs (kubectl not on PATH). Install kubectl or point kubeconfig at GKE."
    return 0
  fi

  local ns inst timeout deploy
  ns="$(jenkins_target_namespace)"
  inst="${RELEASE:-jenkins}"
  timeout="${JENKINS_ROLLOUT_TIMEOUT:-600s}"

  local sel="app.kubernetes.io/name=jenkins,app.kubernetes.io/instance=${inst}"

  if ! kubectl get ns "$ns" --request-timeout="$req" >/dev/null 2>&1; then
    if [[ "$strict" == "1" ]]; then
      die "cannot read namespace $ns (kubeconfig / cluster?). Fix context or set SKIP_JENKINS_WAIT=1."
    fi
    echo "==> Skipping Jenkins wait/logs (namespace $ns not reachable — wrong kubeconfig, VPN, or cluster down)."
    return 0
  fi

  echo "==> Waiting for Jenkins Deployment (namespace=$ns, instance=$inst, timeout=$timeout)"
  deploy="$(kubectl get deployment -n "$ns" -l "$sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$deploy" ]]; then
    echo "    (no Deployment with -l $sel in $ns; skipping wait)"
    if [[ "$strict" == "1" ]]; then
      die "JENKINS_WAIT_STRICT=1 but no Jenkins Deployment found in $ns"
    fi
    return 0
  fi

  if ! kubectl rollout status "deployment/$deploy" -n "$ns" --timeout="$timeout"; then
    echo "warn: Jenkins rollout did not complete (image pull, probes, or timeout). Check: kubectl describe pod -n $ns -l $sel" >&2
    [[ "$strict" == "1" ]] && return 1
    return 0
  fi

  echo "==> Jenkins pod logs (deployment=$deploy namespace=$ns)"
  if [[ "${JENKINS_LOGS_FOLLOW:-}" == "1" ]]; then
    echo "    streaming (JENKINS_LOGS_FOLLOW=1); Ctrl+C to stop"
    kubectl logs -n "$ns" "deployment/$deploy" -f --tail=20 --container=jenkins || {
      echo "warn: could not stream Jenkins logs" >&2
      [[ "$strict" == "1" ]] && return 1
    }
    return 0
  fi

  if ! kubectl logs -n "$ns" "deployment/$deploy" --tail="${JENKINS_LOG_TAIL:-200}" --timestamps --container=jenkins; then
    echo "warn: could not read Jenkins logs" >&2
    [[ "$strict" == "1" ]] && return 1
  fi
}

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
wait_for_jenkins_and_logs
bash "$K8S_HELM" helm "$ENV" platform-ingress

echo "==> deploy-k8s-jenkins done ($ENV). Terraform context: $REPO_ROOT/k8s/scripts/jenkins-gke-env-from-terraform.sh $ENV --export"
