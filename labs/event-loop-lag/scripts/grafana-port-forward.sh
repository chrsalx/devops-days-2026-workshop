#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="event-loop-lag"
KIND_CONTEXT="kind-metrics-labs"
LOCAL_PORT="${1:-3000}"

if [[ "$#" -gt 1 || ! "${LOCAL_PORT}" =~ ^[0-9]+$ ]]; then
  printf 'Usage: %s [local-port] (port must be between 1 and 65535)\n' "$0" >&2
  exit 2
fi
while [[ "${LOCAL_PORT}" == 0* && ${#LOCAL_PORT} -gt 1 ]]; do
  LOCAL_PORT="${LOCAL_PORT#0}"
done
if (( ${#LOCAL_PORT} > 5 )) || (( 10#${LOCAL_PORT} < 1 || 10#${LOCAL_PORT} > 65535 )); then
  printf 'Usage: %s [local-port] (port must be between 1 and 65535)\n' "$0" >&2
  exit 2
fi
if ! command -v kubectl >/dev/null 2>&1; then
  printf 'Required command not found on PATH: kubectl\n' >&2
  exit 1
fi

printf '📊 Forwarding Grafana for %s at http://localhost:%s (press Ctrl-C to stop).\n' "${LAB_NAME}" "${LOCAL_PORT}"
kubectl --context "${KIND_CONTEXT}" port-forward -n monitoring svc/monitoring-grafana "${LOCAL_PORT}:80"