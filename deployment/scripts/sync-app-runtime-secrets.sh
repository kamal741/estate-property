#!/usr/bin/env bash
# Rewrite estateflow-admin-db and estateflow-redis with kubectl stringData (plain text).
# Use after migrating Terraform from data { base64encode(...) } to string_data, or if
#   kubectl get secret ... -o jsonpath='{.data.host}' | base64 -d
# prints base64 text (e.g. MTAuMzAuMC4z) instead of the real host/IP.
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

secret_data_decoded() {
  local ns="$1" secret="$2" key="$3"
  kubectl get secret "$secret" -n "$ns" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null | tr -d '\r\n'
}

cd "$TF_DIR"
NS="$(terraform output -raw gke_namespace)"
PROJECT="$(terraform output -raw gcp_project_id)"
DB_USER="$(terraform output -raw db_user)"
DB_HOST="$(terraform output -raw db_host)"

[[ -n "$NS" && -n "$PROJECT" && -n "$DB_USER" && -n "$DB_HOST" ]] ||
  die "terraform outputs missing (apply infra first?)"

DB_PASS="$(gcloud secrets versions access latest --secret="${ENV}-db-password" --project="$PROJECT")"
REDIS_HOST="$(gcloud secrets versions access latest --secret="${ENV}-redis-host" --project="$PROJECT" 2>/dev/null | tr -d '\r\n')" || true
if [[ -z "$REDIS_HOST" ]]; then
  REDIS_HOST="$(terraform output -raw redis_host)"
fi
REDIS_PASS="$(gcloud secrets versions access latest --secret="${ENV}-redis-auth" --project="$PROJECT")"

[[ -n "$REDIS_HOST" && -n "$REDIS_PASS" ]] || die "redis host/password missing (terraform apply + Secret Manager ${ENV}-redis-host / ${ENV}-redis-auth)"

echo "==> Syncing app runtime secrets in namespace $NS (env=$ENV)"

kubectl get secret estateflow-admin-db -n "$NS" >/dev/null 2>&1 ||
  die "secret estateflow-admin-db not found in $NS (terraform apply with create_app_runtime_secrets=true?)"

kubectl get secret estateflow-redis -n "$NS" >/dev/null 2>&1 ||
  die "secret estateflow-redis not found in $NS (terraform apply with create_app_runtime_secrets=true?)"

kubectl patch secret estateflow-admin-db -n "$NS" --type merge -p "$(
  jq -nc --arg u "$DB_USER" --arg p "$DB_PASS" --arg h "$DB_HOST" \
    '{stringData:{username:$u,password:$p,host:$h}}'
)"

kubectl patch secret estateflow-redis -n "$NS" --type merge -p "$(
  jq -nc --arg h "$REDIS_HOST" --arg p "$REDIS_PASS" \
    '{stringData:{host:$h,password:$p}}'
)"

echo "==> Verify estateflow-admin-db (must be plain text, not nested base64):"
echo -n "    username: "
secret_data_decoded "$NS" estateflow-admin-db username; echo
echo -n "    host:     "
secret_data_decoded "$NS" estateflow-admin-db host; echo

echo "==> Verify estateflow-redis:"
echo -n "    host:     "
secret_data_decoded "$NS" estateflow-redis host; echo
echo "    password: (set, length $(secret_data_decoded "$NS" estateflow-redis password | wc -c | tr -d ' ') chars)"

echo "==> Done. Restart workloads if pods already started: kubectl rollout restart deployment/estateflow-admin-service -n $NS"
