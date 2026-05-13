#!/usr/bin/env bash
# One-shot: Terraform apply for an env, then Helm for Jenkins and platform-ingress (GKE).
# App services are deployed later by Jenkins using jenkins-gke-env-from-terraform.sh outputs.
#
# Usage (from repo root):
#   ./deployment/scripts/deploy-platform.sh <dev|prod>
#
# Environment:
#   SKIP_TERRAFORM=1     Skip terraform apply (only refresh kubeconfig + Helm).
#   TERRAFORM_APPLY_EXTRA  Extra args for terraform apply (e.g. -target=module.infra.google_container_cluster.primary)
#
# Requires: terraform, gcloud, helm, kubectl; GCP auth; terraform init in env dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

[[ "${1:-}" ]] || die "usage: $0 <dev|prod>"

ENV="$1"
TF_DIR="$REPO_ROOT/deployment/terraform/envs/$ENV"
# Helm installs (Jenkins + ingress); not jenkins-gke-env-from-terraform.sh (that only prints TF outputs for CI).
K8S_HELM="$REPO_ROOT/k8s/scripts/deploy.sh"

[[ -d "$TF_DIR" ]] || die "missing terraform env: $TF_DIR"
[[ -f "$K8S_HELM" ]] || die "missing k8s/scripts/deploy.sh"

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
