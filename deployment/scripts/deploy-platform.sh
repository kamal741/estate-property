#!/usr/bin/env bash
# Optional one-shot wrapper (not required): runs terraform-deploy.sh then deploy-k8s-jenkins.sh in order.
# You can delete this file and call those two scripts yourself or from CI; HELM_ONLY=1 here is shorthand for
# "only deploy-k8s-jenkins.sh" with the same env vars.
#
# One-shot: Terraform + kube sync, then Jenkins (Cloud Build or Docker) + ingress Helm.
# Split implementations:
#   ./deployment/scripts/terraform-deploy.sh <env> [state_bucket] [gcs_location]  — infra + kubeconfig only
#   ./deployment/scripts/deploy-k8s-jenkins.sh <env>                          — Cloud Build (default) or Docker push + Helm
#
# Usage (from repo root):
#   ./deployment/scripts/deploy-platform.sh <dev|prod> [terraform_state_bucket] [gcs_bucket_location]
#
# Environment (see terraform-deploy.sh and deploy-k8s-jenkins.sh):
#   HELM_ONLY=1               Skip Terraform path; run deploy-k8s-jenkins.sh only (pass BUILD_PUSH_* etc. through).
#   BUILD_PUSH_JENKINS_IMAGE, ARTIFACT_REGISTRY_REPOSITORY, JENKINS_IMAGE_TAG, JENKINS_BUILD_WITH_DOCKER=1, SKIP_*,
#   TERRAFORM_*, GCP_PROJECT_ID, GCP_REGION, REQUIRE_MANUAL_TFVARS, SKIP_JENKINS_IMAGE_REPOSITORY_AUTO, etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  die "usage: $0 <dev|prod> [terraform_state_bucket] [gcs_bucket_location]
  Wrapper around:
    $SCRIPT_DIR/terraform-deploy.sh   — Terraform + kubeconfig
    $SCRIPT_DIR/deploy-k8s-jenkins.sh  — Jenkins image (gcloud builds submit by default) + Helm
  HELM_ONLY=1 $0 <env>  — only deploy-k8s-jenkins.sh (same env vars as that script)."
}

[[ "${1:-}" ]] || usage

ENV="$1"
shift || true

if [[ "${HELM_ONLY:-}" == "1" ]]; then
  exec bash "$SCRIPT_DIR/deploy-k8s-jenkins.sh" "$ENV"
fi

bash "$SCRIPT_DIR/terraform-deploy.sh" "$ENV" "$@"
bash "$SCRIPT_DIR/deploy-k8s-jenkins.sh" "$ENV"

echo "==> deploy-platform done ($ENV). Jenkins env from Terraform:"
echo "    $REPO_ROOT/k8s/scripts/jenkins-gke-env-from-terraform.sh $ENV --export"
