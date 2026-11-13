#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="file-descriptors"
CLUSTER_NAME="metrics-labs"
KIND_CONTEXT="kind-${CLUSTER_NAME}"

printf '\n🧹 Cleaning up the %s workshop lab\n' "${LAB_NAME}"
printf '   Shared cluster: %s | Kubernetes context: %s\n\n' "${CLUSTER_NAME}" "${KIND_CONTEXT}"

if ! command -v kind >/dev/null 2>&1; then
  printf 'Required command not found on PATH: kind\n' >&2
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  printf 'Required command not found on PATH: kubectl\n' >&2
  exit 1
fi

clusters="$(kind get clusters)"
cluster_exists=false
while IFS= read -r cluster; do
  if [[ "${cluster}" == "${CLUSTER_NAME}" ]]; then
    cluster_exists=true
    break
  fi
done <<< "${clusters}"

if [[ "${cluster_exists}" == false ]]; then
  printf '⏭️ Cluster %s does not exist; nothing to clean up.\n' "${CLUSTER_NAME}"
  exit 0
fi

printf '🗑️ Deleting namespace %s (this lab'\''s app, ScaledObject, and k6 Job only)...\n' "${LAB_NAME}"
kubectl --context "${KIND_CONTEXT}" delete namespace "${LAB_NAME}" --ignore-not-found --wait=true
printf '✅ Lab %s removed. The shared cluster %s and its monitoring stack were left running.\n' "${LAB_NAME}" "${CLUSTER_NAME}"
