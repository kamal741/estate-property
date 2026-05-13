#!/usr/bin/env bash
# Build a Docker image and push to Google Artifact Registry (Docker format).
# AR = Artifact Registry. Host: REGION-docker.pkg.dev
#
# Run from anywhere; build context and Dockerfile paths are resolved from the estate-property repo root.
#
# Usage:
#   ./k8s/scripts/docker-build-push-gcp-ar.sh \
#     --project PROJECT_ID --region REGION --repository REPO \
#     --image IMAGE_NAME --tag TAG --dockerfile PATH [--context DIR]
#
# --dockerfile PATH   Path to Dockerfile relative to the build context directory (see --context).
# --context DIR       Directory under repo root to use as docker build context (default: repo root ".").
#
# Examples:
#   ./k8s/scripts/docker-build-push-gcp-ar.sh --project my-proj --region us-central1 \
#     --repository estateflow --image jenkins --tag dev --dockerfile jenkins/Dockerfile
#
# Requires: docker, gcloud; gcloud auth (e.g. gcloud auth login); AR repository must already exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  sed 's/^  //' >&2 <<'EOF'
  Usage:
    docker-build-push-gcp-ar.sh --project GCP_PROJECT --region GCP_REGION \
      --repository ARTIFACT_REPO_ID --image IMAGE_NAME --tag TAG \
      --dockerfile DOCKERFILE_REL [--context CONTEXT_REL]

  Full image: REGION-docker.pkg.dev/PROJECT/REPOSITORY/IMAGE:TAG

  --context CONTEXT_REL   Optional. Subdirectory of repo root used as docker build context (default: .).
  --dockerfile PATH       Dockerfile path relative to the context directory.
EOF
  exit 1
}

PROJECT=""
REGION=""
REPOSITORY=""
IMAGE=""
TAG=""
DOCKERFILE=""
CONTEXT_REL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --repository) REPOSITORY="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --dockerfile) DOCKERFILE="${2:-}"; shift 2 ;;
    --context) CONTEXT_REL="${2:-}"; shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

[[ -n "$PROJECT" ]] || die "missing --project"
[[ -n "$REGION" ]] || die "missing --region"
[[ -n "$REPOSITORY" ]] || die "missing --repository"
[[ -n "$IMAGE" ]] || die "missing --image"
[[ -n "$TAG" ]] || die "missing --tag"
[[ -n "$DOCKERFILE" ]] || die "missing --dockerfile"

command -v docker >/dev/null || die "docker not on PATH"
command -v gcloud >/dev/null || die "gcloud not on PATH"

# Normalize context: empty means repo root
if [[ -z "$CONTEXT_REL" || "$CONTEXT_REL" == "." ]]; then
  BUILD_CONTEXT="$REPO_ROOT"
else
  BUILD_CONTEXT="$REPO_ROOT/${CONTEXT_REL#/}"
fi
[[ -d "$BUILD_CONTEXT" ]] || die "build context is not a directory: $BUILD_CONTEXT"

REGISTRY_HOST="${REGION}-docker.pkg.dev"
FULL_IMAGE="${REGISTRY_HOST}/${PROJECT}/${REPOSITORY}/${IMAGE}:${TAG}"

echo "==> docker-build-push-gcp-ar: configure Docker for ${REGISTRY_HOST}"
gcloud auth configure-docker "${REGISTRY_HOST}" --quiet

echo "==> docker-build-push-gcp-ar: docker build -f ${DOCKERFILE} -t ${FULL_IMAGE}"
echo "    context: ${BUILD_CONTEXT}"
docker build -f "${DOCKERFILE}" -t "${FULL_IMAGE}" "${BUILD_CONTEXT}"

echo "==> docker-build-push-gcp-ar: docker push ${FULL_IMAGE}"
docker push "${FULL_IMAGE}"

echo "==> pushed: ${FULL_IMAGE}"
