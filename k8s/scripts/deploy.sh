#!/usr/bin/env bash
# Deploy to GKE: Helm charts (k8s/services/charts) or kubectl apply / Kustomize (k8s/env/<env>/manifests).
# Run from repo root. Examples:
#   ./k8s/scripts/deploy.sh dev jenkins
#   ./k8s/scripts/deploy.sh dev jenkins --set-string image.tag=v1.0.0
#   JENKINS_IMAGE_TAG=v1.0.0 ./k8s/scripts/deploy.sh dev jenkins
# GKE: SYNC_GKE_KUBECONFIG=1 runs terraform output gke_get_credentials_command in deployment/terraform/envs/<env>/
# Helm env vars: RELEASE, NAMESPACE, JENKINS_HELM_NAMESPACE, JENKINS_IMAGE_TAG, JENKINS_IMAGE_REPOSITORY, HELM_UPGRADE_FORCE=1, … ./k8s/scripts/deploy.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

show_usage() {
  local fd="${1:-2}"
  sed 's/^  //' >&"$fd" <<'EOF'
  Usage:
    deploy.sh [--help] <env> <service> [helm args...]
    deploy.sh helm <env> <service> [helm args...]
    deploy.sh kubectl <env> [path-from-repo-root] [kubectl apply args...]

  Helm: chart k8s/services/charts/<service>, values k8s/env/<env>/<service>-values.yaml.
    Anything after <service> is passed through to `helm upgrade` (e.g. --set-string image.tag=v1.0.0 for Jenkins).
    By default Helm does **not** pass --create-namespace (Terraform creates gke_namespace; CI SAs often lack cluster-scoped
    namespace create). Set HELM_CREATE_NAMESPACE=1 to add --create-namespace for greenfield installs.
  kubectl: default path k8s/env/<env>/manifests (kustomization.yaml → apply -k, else apply -f)
  GKE: SYNC_GKE_KUBECONFIG=1 → terraform gke_get_credentials_command from deployment/terraform/envs/<env>/

  Jenkins image.repository (no per-file project id required), highest precedence first:
    JENKINS_IMAGE_REPOSITORY=REGION-docker.pkg.dev/PROJECT/REPO/jenkins  (full path, no tag)
    GCP_PROJECT_ID + GCP_REGION + ARTIFACT_REGISTRY_REPOSITORY  (same path is built; optional JENKINS_AR_IMAGE_NAME, default jenkins)
    Else if SKIP_JENKINS_IMAGE_REPOSITORY_AUTO is unset: terraform output jenkins_image_repository from deployment/terraform/envs/<env>
    SKIP_JENKINS_IMAGE_REPOSITORY_AUTO=1  → do not inject; use values + chart defaults only
  Jenkins image.tag: use env JENKINS_IMAGE_TAG=v1.0.0, or pass Helm args after the service name, e.g.
    ./k8s/scripts/deploy.sh dev jenkins --set-string image.tag=v1.0.0
    Trailing args are applied after this script’s --set-string flags, so they win for the same key.
  estateflow-admin-service image.repository (same precedence idea as Jenkins), highest precedence first:
    ESTATEFLOW_ADMIN_SERVICE_IMAGE_REPOSITORY=REGION-docker.pkg.dev/PROJECT/REPO/estateflow-admin-service  (full path, no tag)
    GCP_PROJECT_ID + GCP_REGION + ARTIFACT_REGISTRY_REPOSITORY  → .../estateflow-admin-service
    Else if SKIP_ESTATEFLOW_ADMIN_SERVICE_IMAGE_REPOSITORY_AUTO is unset: terraform output
    artifact_registry_docker_prefix from deployment/terraform/envs/<env>, then /estateflow-admin-service
    If that output is missing (old state), falls back to stripping /jenkins from jenkins_image_repository.
    SKIP_ESTATEFLOW_ADMIN_SERVICE_IMAGE_REPOSITORY_AUTO=1  → do not inject; use values + chart defaults only
  estateflow-admin-service databaseHost (JDBC URLs), highest precedence first:
    DATABASE_HOST or DB_PRIVATE_IP  (Cloud SQL IP or hostname)
    Else: kubectl secret estateflow-admin-db key host (namespace from NAMESPACE or gke_namespace)
    Else: gcloud secrets versions access latest --secret=<env>-db-host (needs GCP_PROJECT_ID)
    Else if SKIP_DATABASE_HOST_AUTO is unset: terraform output db_host (then db_private_ip / db_public_ip)
    SKIP_DATABASE_HOST_AUTO=1  → do not inject (not recommended for GKE; chart falls back to docker-compose postgres URLs)
  Jenkins Helm namespace: defaults to Terraform output gke_namespace (e.g. dev-estateflow), else <env>-estateflow.
    Override with NAMESPACE=... or JENKINS_HELM_NAMESPACE=... (NAMESPACE wins).
  Helm upgrades: HELM_UPGRADE_FORCE=1 fixes SSA field conflicts by forcing resource replacement. On Helm 4+ this uses
    --server-side=false --force-replace (they cannot be combined with SSA). On older Helm, --force is used instead.
    Not applied to the jenkins chart: force-replace hits the bound Jenkins PVC (immutable spec / volumeName). For Service
    drift on Jenkins, delete the Service and redeploy without HELM_UPGRADE_FORCE (see k8s/env/<env>/jenkins-values.yaml).
  Extra helm args: any other `helm upgrade` flags (e.g. --set key=val, --dry-run).
EOF
}

# Same namespace Terraform uses for app workloads (kubernetes_namespace_v1.app).
jenkins_helm_target_namespace() {
  local env="$1"
  if [[ -n "${JENKINS_HELM_NAMESPACE:-}" ]]; then
    printf '%s' "${JENKINS_HELM_NAMESPACE}"
    return 0
  fi
  local tfdir="$REPO_ROOT/deployment/terraform/envs/$env"
  if [[ -d "$tfdir" ]] && command -v terraform >/dev/null 2>&1; then
    local out
    out="$(cd "$tfdir" && terraform output -raw gke_namespace 2>/dev/null)" || true
    if [[ -n "$out" ]]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  printf '%s-estateflow' "$env"
}

# Resolves Helm image.repository for Jenkins (no tag). Empty = do not pass --set-string.
jenkins_resolve_image_repository() {
  local env="$1"
  if [[ -n "${JENKINS_IMAGE_REPOSITORY:-}" ]]; then
    printf '%s' "$JENKINS_IMAGE_REPOSITORY"
    return 0
  fi
  if [[ "${SKIP_JENKINS_IMAGE_REPOSITORY_AUTO:-}" == "1" ]]; then
    return 0
  fi
  if [[ -n "${GCP_PROJECT_ID:-}" && -n "${GCP_REGION:-}" && -n "${ARTIFACT_REGISTRY_REPOSITORY:-}" ]]; then
    local img="${JENKINS_AR_IMAGE_NAME:-jenkins}"
    printf '%s' "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${ARTIFACT_REGISTRY_REPOSITORY}/${img}"
    return 0
  fi
  local tfdir="$REPO_ROOT/deployment/terraform/envs/$env"
  if [[ -d "$tfdir" ]] && command -v terraform >/dev/null 2>&1; then
    local out
    out="$(cd "$tfdir" && terraform output -raw jenkins_image_repository 2>/dev/null)" || true
    if [[ -n "$out" ]]; then
      printf '%s' "$out"
    fi
  fi
}

is_estateflow_image_service() {
  case "${1:-}" in
    estateflow-admin-service | estateflow-brokerage-agent-service | estateflow-client-service | estateflow-admin-ui)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_estateflow_jdbc_service() {
  case "${1:-}" in
    estateflow-admin-service | estateflow-brokerage-agent-service | estateflow-client-service)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Full Artifact Registry path for an EstateFlow image (no tag). image_name = chart / AR image name.
estateflow_resolve_image_repository() {
  local env="$1" image_name="$2"
  if [[ "$image_name" == "estateflow-admin-service" && -n "${ESTATEFLOW_ADMIN_SERVICE_IMAGE_REPOSITORY:-}" ]]; then
    printf '%s' "${ESTATEFLOW_ADMIN_SERVICE_IMAGE_REPOSITORY}"
    return 0
  fi
  if [[ "${SKIP_ESTATEFLOW_IMAGE_REPOSITORY_AUTO:-}" == "1" || "${SKIP_ESTATEFLOW_ADMIN_SERVICE_IMAGE_REPOSITORY_AUTO:-}" == "1" ]]; then
    return 0
  fi
  if [[ -n "${GCP_PROJECT_ID:-}" && -n "${GCP_REGION:-}" && -n "${ARTIFACT_REGISTRY_REPOSITORY:-}" ]]; then
    printf '%s' "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${ARTIFACT_REGISTRY_REPOSITORY}/${image_name}"
    return 0
  fi
  local tfdir="$REPO_ROOT/deployment/terraform/envs/$env"
  if [[ -d "$tfdir" ]] && command -v terraform >/dev/null 2>&1; then
    local prefix jenkins_repo
    prefix="$(cd "$tfdir" && terraform output -raw artifact_registry_docker_prefix 2>/dev/null)" || true
    if [[ -n "$prefix" ]]; then
      printf '%s' "${prefix}/${image_name}"
      return 0
    fi
    jenkins_repo="$(cd "$tfdir" && terraform output -raw jenkins_image_repository 2>/dev/null)" || true
    if [[ -n "$jenkins_repo" && "$jenkins_repo" == */jenkins ]]; then
      printf '%s' "${jenkins_repo%/jenkins}/${image_name}"
    fi
  fi
}

estateflow_admin_service_resolve_image_repository() {
  estateflow_resolve_image_repository "$1" "estateflow-admin-service"
}

# Cloud SQL host for JDBC URL generation in the admin-service chart (no jdbc: prefix).
estateflow_admin_service_resolve_database_host() {
  local env="$1"
  local ns="${NAMESPACE:-}"
  if [[ -z "$ns" ]]; then
    ns="$(jenkins_helm_target_namespace "$env")"
  fi
  if [[ -n "${DATABASE_HOST:-}" ]]; then
    printf '%s' "${DATABASE_HOST}"
    return 0
  fi
  if [[ -n "${DB_PRIVATE_IP:-}" ]]; then
    printf '%s' "${DB_PRIVATE_IP}"
    return 0
  fi
  if [[ "${SKIP_DATABASE_HOST_AUTO:-}" == "1" ]]; then
    return 0
  fi
  if command -v kubectl >/dev/null 2>&1 && [[ -n "$ns" ]]; then
    local from_secret
    from_secret="$(kubectl get secret estateflow-admin-db -n "$ns" -o jsonpath='{.data.host}' 2>/dev/null \
      | base64 -d 2>/dev/null | tr -d '\r\n')" || true
    if [[ -n "$from_secret" ]]; then
      printf '%s' "$from_secret"
      return 0
    fi
  fi
  if command -v gcloud >/dev/null 2>&1; then
    local project="${GCP_PROJECT_ID:-}"
    if [[ -z "$project" && -n "${PROJECT_ID:-}" ]]; then
      project="$PROJECT_ID"
    fi
    if [[ -n "$project" ]]; then
      local from_sm
      from_sm="$(gcloud secrets versions access latest --secret="${env}-db-host" --project="$project" 2>/dev/null \
        | tr -d '\r\n')" || true
      if [[ -n "$from_sm" ]]; then
        printf '%s' "$from_sm"
        return 0
      fi
    fi
  fi
  local tfdir="$REPO_ROOT/deployment/terraform/envs/$env"
  if [[ ! -d "$tfdir" ]] || ! command -v terraform >/dev/null 2>&1; then
    return 0
  fi
  local host private public
  host="$(cd "$tfdir" && terraform output -raw db_host 2>/dev/null)" || true
  if [[ -n "$host" && "$host" != "null" ]]; then
    printf '%s' "$host"
    return 0
  fi
  private="$(cd "$tfdir" && terraform output -raw db_private_ip 2>/dev/null)" || true
  if [[ -n "$private" && "$private" != "null" ]]; then
    printf '%s' "$private"
    return 0
  fi
  public="$(cd "$tfdir" && terraform output -raw db_public_ip 2>/dev/null)" || true
  if [[ -n "$public" && "$public" != "null" ]]; then
    printf '%s' "$public"
  fi
}

sync_kubeconfig_if_requested() {
  local env="$1"
  case "${SYNC_GKE_KUBECONFIG:-}" in 1 | true | yes) ;; *) return 0 ;; esac

  local tfdir="$REPO_ROOT/deployment/terraform/envs/$env"
  [[ -d "$tfdir" ]] || die "SYNC_GKE_KUBECONFIG=1 but missing $tfdir"
  command -v terraform >/dev/null || die "SYNC_GKE_KUBECONFIG=1 requires terraform on PATH"

  pushd "$tfdir" >/dev/null || exit 1
  terraform output gke_get_credentials_command >/dev/null 2>&1 ||
    die "terraform output gke_get_credentials_command unavailable in $tfdir"

  local cmd
  cmd="$(terraform output -raw gke_get_credentials_command)"
  echo "==> GKE kubeconfig ($env): $cmd"
  eval "$cmd"
  if terraform output gke_namespace >/dev/null 2>&1; then
    echo "    Terraform app namespace: $(terraform output -raw gke_namespace)"
  fi
  popd >/dev/null || true
}

helm_namespace() {
  local service="$1"
  local env="$2"
  [[ -n "${NAMESPACE:-}" ]] && { echo "$NAMESPACE"; return; }
  case "$service" in
    jenkins) jenkins_helm_target_namespace "$env" ;;
    platform-ingress) echo kube-system ;;
    *) jenkins_helm_target_namespace "$env" ;;
  esac
}

helm_upgrade() {
  local env="$1" service="$2"
  shift 2 || true

  local env_dir="$REPO_ROOT/k8s/env/$env"
  local chart="$REPO_ROOT/k8s/services/charts/$service"
  local values="$env_dir/${service}-values.yaml"

  [[ -d "$env_dir" ]] || die "env directory missing: $env_dir"
  [[ -d "$chart" ]] || die "chart directory missing: $chart"
  [[ -f "$chart/Chart.yaml" ]] || die "not a Helm chart: $chart"
  [[ -f "$values" ]] || die "values missing: $values (add k8s/env/$env/${service}-values.yaml)"

  local release="${RELEASE:-$service}"
  local ns
  ns="$(helm_namespace "$service" "$env")"

  local jenkins_image_overrides=()
  local estateflow_image_overrides=()
  if [[ "$service" == "jenkins" ]]; then
    local resolved
    resolved="$(jenkins_resolve_image_repository "$env")"
    if [[ -n "$resolved" ]]; then
      jenkins_image_overrides+=(--set-string "image.repository=$resolved")
      echo "    (Jenkins image.repository from env/terraform: $resolved)"
    fi
    if [[ -n "${JENKINS_IMAGE_TAG:-}" ]]; then
      jenkins_image_overrides+=(--set-string "image.tag=${JENKINS_IMAGE_TAG}")
      echo "    (Jenkins image.tag from JENKINS_IMAGE_TAG: ${JENKINS_IMAGE_TAG})"
    fi
  elif is_estateflow_image_service "$service"; then
    local ef_repo db_host
    ef_repo="$(estateflow_resolve_image_repository "$env" "$service")"
    if [[ -n "$ef_repo" ]]; then
      estateflow_image_overrides+=(--set-string "image.repository=$ef_repo")
      echo "    ($service image.repository from env/terraform: $ef_repo)"
    fi
    if is_estateflow_jdbc_service "$service"; then
      db_host="$(estateflow_admin_service_resolve_database_host "$env")"
      if [[ -n "$db_host" ]]; then
        estateflow_image_overrides+=(--set-string "databaseHost=$db_host")
        echo "    ($service databaseHost for JDBC URLs: $db_host)"
      else
        echo "    (WARN: $service databaseHost unset — JDBC URLs will use chart docker-compose defaults (postgres:5432). Set DATABASE_HOST or run terraform output db_private_ip.)" >&2
      fi
    fi
  fi

  local helm_upgrade_extra=()
  if [[ "${HELM_UPGRADE_FORCE:-}" == "1" ]]; then
    if [[ "$service" == "jenkins" ]]; then
      echo "    (HELM_UPGRADE_FORCE ignored for jenkins: --force-replace breaks bound PVCs; omit HELM_UPGRADE_FORCE or delete conflicting Service — k8s/env/$env/jenkins-values.yaml)"
    else
      local helm_help
      helm_help="$(helm upgrade -h 2>&1 || true)"
      if grep -q -- '--force-replace' <<<"$helm_help" && grep -q -- '--server-side' <<<"$helm_help"; then
        helm_upgrade_extra+=(--server-side=false --force-replace)
        echo "    (HELM_UPGRADE_FORCE=1: helm --server-side=false --force-replace)"
      else
        helm_upgrade_extra+=(--force)
        echo "    (HELM_UPGRADE_FORCE=1: helm --force)"
      fi
    fi
  fi

  local helm_ns_create=()
  if [[ "${HELM_CREATE_NAMESPACE:-}" == "1" ]]; then
    helm_ns_create=(--create-namespace)
    echo "    (HELM_CREATE_NAMESPACE=1: helm --create-namespace)"
  fi

  echo "==> helm upgrade --install release=$release namespace=$ns (env=$env service=$service)"
  echo "    $chart"
  echo "    -f $values"
  echo
  helm upgrade --install "$release" "$chart" \
    --namespace "$ns" \
    "${helm_ns_create[@]}" \
    --values "$values" \
    "${jenkins_image_overrides[@]}" \
    "${estateflow_image_overrides[@]}" \
    "${helm_upgrade_extra[@]}" \
    "$@"
}

kubectl_apply() {
  local env="$1"
  shift

  local rel target
  if [[ "${1:-}" && "${1:-}" != -* ]]; then
    rel="$1"
    shift
  else
    rel="k8s/env/$env/manifests"
  fi
  [[ "$rel" = /* ]] && target="$rel" || target="$REPO_ROOT/$rel"

  [[ -e "$target" ]] || die "kubectl target missing: $target"
  [[ -d "$REPO_ROOT/k8s/env/$env" ]] || die "env directory missing: $REPO_ROOT/k8s/env/$env"

  echo "==> kubectl apply (env=$env)"
  echo "    $target"
  echo

  if [[ -f "$target" ]]; then
    kubectl apply -f "$target" "$@"
    return
  fi
  [[ -d "$target" ]] || die "not a file or directory: $target"

  if [[ -f "$target/kustomization.yaml" || -f "$target/kustomization.yml" ]]; then
    kubectl apply -k "$target" "$@"
  else
    kubectl apply -f "$target" "$@"
  fi
}

# --- main ---
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_usage 1; exit 0; }
[[ $# -ge 1 ]] || { show_usage; exit 1; }

mode=helm
[[ "${1:-}" == "kubectl" ]] && { mode=kubectl; shift; }
[[ "${1:-}" == "helm" ]] && { mode=helm; shift; }

if [[ "$mode" == "kubectl" ]]; then
  [[ "${1:-}" ]] || { show_usage; exit 1; }
  env="$1"
  shift
  sync_kubeconfig_if_requested "$env"
  kubectl_apply "$env" "$@"
  exit 0
fi

[[ "${1:-}" && "${2:-}" ]] || { show_usage; exit 1; }
env="$1"
service="$2"
shift 2 || true
sync_kubeconfig_if_requested "$env"
helm_upgrade "$env" "$service" "$@"
