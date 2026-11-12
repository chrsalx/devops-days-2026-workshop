#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="metrics-http-client-pool"

if ! command -v kind >/dev/null 2>&1; then
  printf 'Required command not found on PATH: kind\n' >&2
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
  printf 'Cluster %s does not exist; nothing to clean up.\n' "${CLUSTER_NAME}"
  exit 0
fi

kind delete cluster --name "${CLUSTER_NAME}"