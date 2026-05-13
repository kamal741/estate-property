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
  Jenkins Helm namespace: defaults to Terraform output gke_namespace (e.g. dev-estateflow), else <env>-estateflow.
    Override with NAMESPACE=... or JENKINS_HELM_NAMESPACE=... (NAMESPACE wins).
  Helm upgrades: HELM_UPGRADE_FORCE=1 adds helm --force (replace resources) — use once if SSA reports a conflict
    (e.g. Service spec.type was changed with kubectl patch outside Helm).
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
    *) echo "$service" ;;
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
  fi

  local helm_upgrade_extra=()
  [[ "${HELM_UPGRADE_FORCE:-}" == "1" ]] && {
    helm_upgrade_extra+=(--force)
    echo "    (HELM_UPGRADE_FORCE=1: passing --force to helm upgrade — replaces conflicting resources)"
  }

  echo "==> helm upgrade --install release=$release namespace=$ns (env=$env service=$service)"
  echo "    $chart"
  echo "    -f $values"
  echo
  helm upgrade --install "$release" "$chart" \
    --namespace "$ns" \
    --create-namespace \
    --values "$values" \
    "${jenkins_image_overrides[@]}" \
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
