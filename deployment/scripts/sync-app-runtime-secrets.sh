#!/usr/bin/env bash
# Rewrite estateflow-admin-db and estateflow-redis with kubectl stringData (plain text).
# Use after migrating Terraform from data { base64encode(...) } to string_data, or if
# kubectl get secret ... -o jsonpath='{.data.username}' | base64 -d shows base64 text
# instead of the real username (double-encoding).
#
# Usage (from repo root):
#   ./deployment/scripts/sync-app-runtime-secrets.sh dev
#   ./deployment/scripts/sync-app-runtime-secrets.sh prod
#
# Requires: terraform, kubectl, gcloud, jq; kubecontext must target the env cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

[[ "${1:-}" ]] || die "usage: $0 <dev|prod>"

ENV="$1"
TF_DIR="$REPO_ROOT/deployment/terraform/envs/$ENV"
[[ -d "$TF_DIR" ]] || die "missing $TF_DIR"

command -v terraform >/dev/null || die "terraform required"
command -v kubectl >/dev/null || die "kubectl required"
command -v gcloud >/dev/null || die "gcloud required"
command -v jq >/dev/null || die "jq required"

cd "$TF_DIR"
NS="$(terraform output -raw gke_namespace)"
PROJECT="$(terraform output -raw gcp_project_id)"
DB_USER="$(terraform output -raw db_user)"
DB_HOST="$(terraform output -raw db_host)"
REDIS_HOST="$(terraform output -raw redis_host)"

[[ -n "$NS" && -n "$PROJECT" && -n "$DB_USER" && -n "$DB_HOST" && -n "$REDIS_HOST" ]] ||
  die "terraform outputs missing (apply infra first?)"

DB_PASS="$(gcloud secrets versions access latest --secret="${ENV}-db-password" --project="$PROJECT")"
REDIS_PASS="$(gcloud secrets versions access latest --secret="${ENV}-redis-auth" --project="$PROJECT")"

echo "==> Syncing app runtime secrets in namespace $NS (env=$ENV)"

kubectl get secret estateflow-admin-db -n "$NS" >/dev/null 2>&1 ||
  die "secret estateflow-admin-db not found in $NS (terraform apply with create_app_runtime_secrets=true?)"

kubectl patch secret estateflow-admin-db -n "$NS" --type merge -p "$(
  jq -nc --arg u "$DB_USER" --arg p "$DB_PASS" --arg h "$DB_HOST" \
    '{stringData:{username:$u,password:$p,host:$h}}'
)"

kubectl get secret estateflow-redis -n "$NS" >/dev/null 2>&1 &&
  kubectl patch secret estateflow-redis -n "$NS" --type merge -p "$(
    jq -nc --arg h "$REDIS_HOST" --arg p "$REDIS_PASS" \
      '{stringData:{host:$h,password:$p}}'
  )" || echo "    (skip estateflow-redis: not found)"

echo "==> Verify (should print real values, not base64 blobs like cG9zdGdyZXM= for user postgres):"
echo -n "    username: "
kubectl get secret estateflow-admin-db -n "$NS" -o jsonpath='{.data.username}' | base64 -d; echo
echo -n "    host:     "
kubectl get secret estateflow-admin-db -n "$NS" -o jsonpath='{.data.host}' | base64 -d; echo
