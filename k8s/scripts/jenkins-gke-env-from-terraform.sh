#!/usr/bin/env bash
# Print GKE settings from Terraform for Jenkins jobs (cluster, namespaces, gcloud get-credentials).
# No secrets. In Jenkins: authenticate GCP (e.g. Secret file → GOOGLE_APPLICATION_CREDENTIALS +
# gcloud auth activate-service-account --key-file=...), then run the get-credentials command, then helm/kubectl.
#
# Usage (from repo root):
#   ./k8s/scripts/jenkins-gke-env-from-terraform.sh <dev|prod> [--text | --json | --export]
#
#   --text   default: terraform human-readable output (no jq)
#   --json   JSON object (.value only); requires jq
#   --export shell exports (eval in a pipeline step); requires jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

[[ "${1:-}" ]] || die "usage: $0 <dev|prod> [--text|--json|--export]"

ENV="$1"
shift || true

FMT="--text"
if [[ "${1:-}" == --text || "${1:-}" == --json || "${1:-}" == --export ]]; then
  FMT="$1"
  shift
fi

TF_DIR="$REPO_ROOT/deployment/terraform/envs/$ENV"
[[ -d "$TF_DIR" ]] || die "missing $TF_DIR"

pushd "$TF_DIR" >/dev/null || exit 1
terraform output jenkins_gke_context >/dev/null 2>&1 || die "output jenkins_gke_context missing (terraform apply / init?)"

case "$FMT" in
  --text)
    terraform output jenkins_gke_context
    ;;
  --json)
    command -v jq >/dev/null || die "install jq for --json"
    terraform output -json jenkins_gke_context | jq '.value'
    ;;
  --export)
    command -v jq >/dev/null || die "install jq for --export"
    terraform output -json jenkins_gke_context | jq -r '.value | to_entries[] | "export \(.key)=\(.value|@sh)"'
    ;;
  *)
    die "unknown option: $FMT"
    ;;
esac

popd >/dev/null || true
