#!/usr/bin/env bash
# Deploy to GKE: Helm charts (k8s/services/charts) or kubectl apply / Kustomize (k8s/env/<env>/manifests).
# Run from repo root. Examples: ./k8s/scripts/deploy.sh dev jenkins | ./k8s/scripts/deploy.sh kubectl dev
# GKE: SYNC_GKE_KUBECONFIG=1 runs terraform output gke_get_credentials_command in deployment/terraform/envs/<env>/
# Helm env vars: RELEASE, NAMESPACE.  ./k8s/scripts/deploy.sh --help

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

  Helm: chart k8s/services/charts/<service>, values k8s/env/<env>/<service>-values.yaml
  kubectl: default path k8s/env/<env>/manifests (kustomization.yaml → apply -k, else apply -f)
  GKE: SYNC_GKE_KUBECONFIG=1 → terraform gke_get_credentials_command from deployment/terraform/envs/<env>/
EOF
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
  [[ -n "${NAMESPACE:-}" ]] && { echo "$NAMESPACE"; return; }
  case "$service" in
    jenkins) echo jenkins ;;
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
  ns="$(helm_namespace "$service")"

  echo "==> helm upgrade --install release=$release namespace=$ns (env=$env service=$service)"
  echo "    $chart"
  echo "    -f $values"
  echo
  helm upgrade --install "$release" "$chart" \
    --namespace "$ns" \
    --create-namespace \
    --values "$values" \
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
