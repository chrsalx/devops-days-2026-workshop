#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="file-descriptors"
CLUSTER_NAME="metrics-labs"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
IMAGE="workshop-${LAB_NAME}:local"

for command_name in docker kind; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command not found on PATH: %s\n' "${command_name}" >&2
    exit 1
  fi
done

if ! docker buildx version >/dev/null 2>&1; then
  printf 'Docker Buildx is required to build the lab image.\n' >&2
  exit 1
fi

clusters="$(kind get clusters)"
if ! printf '%s\n' "${clusters}" | while IFS= read -r cluster; do
  [[ "${cluster}" == "${CLUSTER_NAME}" ]] && exit 0
done; then
  printf 'Kind cluster %s does not exist. Run %s/scripts/setup.sh first.\n' "${CLUSTER_NAME}" "${LAB_DIR}" >&2
  exit 1
fi

case "$(docker info --format '{{.OSType}}/{{.Architecture}}')" in
  linux/amd64|linux/x86_64) platform="linux/amd64" ;;
  linux/arm64|linux/aarch64) platform="linux/arm64" ;;
  *) printf 'Unsupported Docker platform for kind image loading.\n' >&2; exit 1 ;;
esac

printf '🔨 Building %s with Docker Buildx for %s...\n' "${IMAGE}" "${platform}"
docker buildx build --platform "${platform}" --load \
  --file "${LAB_DIR}/Dockerfile" --tag "${IMAGE}" "${ROOT_DIR}"
printf '📦 Loading %s into kind cluster %s...\n' "${IMAGE}" "${CLUSTER_NAME}"
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}"
printf '✅ Image build and cluster load complete.\n'