#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
LABS=(database-connections file-descriptors request-queue http-client-pool event-loop-lag)

kind() {
  printf 'kind %s\n' "$*" >&2
  if [[ "$*" == "get clusters" ]]; then
    printf '%s\n' "${MOCK_CLUSTERS:-}"
  fi
}

kubectl() {
  printf 'kubectl %s\n' "$*" >&2
  if [[ -n "${MOCK_KUBECTL_FAIL:-}" && "$*" == *"${MOCK_KUBECTL_FAIL}"* ]]; then
    return 43
  fi
  if [[ "$*" == *"get statefulset prometheus-monitoring-kube-prometheus-prometheus"* ]]; then
    printf 'statefulset.apps/prometheus-monitoring-kube-prometheus-prometheus\n'
  fi
}

helm() {
  printf 'helm %s\n' "$*" >&2
  if [[ "$*" == "list --all --short --namespace monitoring --kube-context "* ]]; then
    printf '%s\n' "${MOCK_RELEASES:-}"
    return 0
  fi
  if [[ -n "${MOCK_HELM_FAIL:-}" && "$*" == *"${MOCK_HELM_FAIL}"* ]]; then
    return 42
  fi
}

export -f kind kubectl helm

assert_contains() {
  if [[ "$1" != *"$2"* ]]; then
    printf 'Expected output to contain: %s\n%s\n' "$2" "$1" >&2
    exit 1
  fi
}

assert_not_contains() {
  if [[ "$1" == *"$2"* ]]; then
    printf 'Expected output not to contain: %s\n%s\n' "$2" "$1" >&2
    exit 1
  fi
}

all_clusters="metrics-lab
metrics-labs
metrics-database-connections
metrics-file-descriptors
metrics-request-queue
metrics-http-client-pool
metrics-event-loop-lag"

for lab in "${LABS[@]}"; do
  cluster="metrics-${lab}"
  context="kind-${cluster}"
  setup="${ROOT_DIR}/${lab}/setup.sh"
  cleanup="${ROOT_DIR}/${lab}/cleanup.sh"

  output="$(MOCK_CLUSTERS="${all_clusters}" "${setup}" 2>&1)"
  assert_contains "${output}" "kubectl --context ${context} cluster-info"
  assert_contains "${output}" "kubectl --context ${context} create namespace monitoring --dry-run=client -o yaml"
  assert_contains "${output}" "helm list --all --short --namespace monitoring --kube-context ${context}"
  assert_contains "${output}" "kubectl --context ${context} apply -f ${ROOT_DIR}/tools/k6/configmap.yaml"
  assert_contains "${output}" "helm repo update prometheus-community kedacore"
  assert_contains "${output}" "helm upgrade --install monitoring prometheus-community/kube-prometheus-stack --version 93.2.2 --namespace monitoring --create-namespace --values ${ROOT_DIR}/monitoring/kube-prometheus-stack-values.yaml --kube-context ${context} --wait --timeout 5m"
  assert_not_contains "${output}" "prometheus-community/prometheus"
  assert_not_contains "${output}" "grafana-community/grafana"
  assert_contains "${output}" "--version 2.21.0"
  assert_contains "${output}" "--values ${ROOT_DIR}/monitoring/keda-values.yaml --kube-context ${context}"
  assert_contains "${output}" "kubectl --context ${context} wait --for=condition=Established"
  assert_contains "${output}" "crd/prometheuses.monitoring.coreos.com"
  assert_contains "${output}" "kubectl --context ${context} rollout status deployment/monitoring-kube-prometheus-operator -n monitoring --timeout=180s"
  assert_contains "${output}" "kubectl --context ${context} get statefulset prometheus-monitoring-kube-prometheus-prometheus -n monitoring --ignore-not-found -o name"
  assert_contains "${output}" "kubectl --context ${context} rollout status statefulset/prometheus-monitoring-kube-prometheus-prometheus -n monitoring --timeout=180s"
  assert_contains "${output}" "kubectl --context ${context} rollout status deployment/monitoring-grafana -n monitoring --timeout=180s"
  assert_contains "${output}" "kubectl --context ${context} apply -k ${ROOT_DIR}/monitoring/cadvisor"
  assert_contains "${output}" "kubectl --context ${context} rollout status daemonset/cadvisor -n monitoring --timeout=180s"
  assert_contains "${output}" "kubectl --context ${context} apply -k ${ROOT_DIR}/monitoring/grafana"
  assert_not_contains "${output}" "kind create cluster"
  printf '%s: existing-cluster setup targets its own context\n' "${lab}"

  output="$(MOCK_CLUSTERS="" "${setup}" 2>&1)"
  assert_contains "${output}" "kind create cluster --name ${cluster} --wait 120s"
  assert_contains "${output}" "kubectl --context ${context} cluster-info"
  assert_not_contains "${output}" "kind create cluster --name metrics-labs"
  printf '%s: missing-cluster setup creates only its cluster\n' "${lab}"

  output="$(MOCK_CLUSTERS="${all_clusters}" "${cleanup}" 2>&1)"
  assert_contains "${output}" "kind delete cluster --name ${cluster}"
  assert_not_contains "${output}" "kind delete cluster --name metrics-labs"
  assert_not_contains "${output}" "kind delete cluster --name metrics-lab"
  printf '%s: cleanup deletes only its cluster\n' "${lab}"

  output="$(MOCK_CLUSTERS="metrics-lab
metrics-labs" "${cleanup}" 2>&1)"
  assert_contains "${output}" "Cluster ${cluster} does not exist; nothing to clean up."
  assert_not_contains "${output}" "kind delete cluster"
  printf '%s: absent-cluster cleanup is a no-op\n' "${lab}"

  set +e
  MOCK_CLUSTERS="${cluster}" MOCK_HELM_FAIL="prometheus-community/kube-prometheus-stack" \
    "${setup}" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "${status}" -ne 42 ]]; then
    printf '%s: setup did not propagate Helm failure (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  printf '%s: setup propagates monitoring chart failures\n' "${lab}"

  set +e
  MOCK_CLUSTERS="${cluster}" MOCK_HELM_FAIL="kedacore/keda" \
    "${setup}" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "${status}" -ne 42 ]]; then
    printf '%s: setup did not propagate KEDA Helm failure (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  printf '%s: setup propagates KEDA Helm failures\n' "${lab}"

  set +e
  MOCK_CLUSTERS="${cluster}" MOCK_KUBECTL_FAIL="apply -k ${ROOT_DIR}/monitoring/cadvisor" \
    "${setup}" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "${status}" -ne 43 ]]; then
    printf '%s: setup did not propagate cAdvisor apply failure (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  printf '%s: setup propagates cAdvisor apply failures\n' "${lab}"

  set +e
  MOCK_CLUSTERS="${cluster}" MOCK_KUBECTL_FAIL="rollout status daemonset/cadvisor" \
    "${setup}" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "${status}" -ne 43 ]]; then
    printf '%s: setup did not propagate cAdvisor rollout failure (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  printf '%s: setup propagates cAdvisor rollout failures\n' "${lab}"

  set +e
  MOCK_CLUSTERS="${cluster}" MOCK_KUBECTL_FAIL="apply -k ${ROOT_DIR}/monitoring/grafana" \
    "${setup}" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "${status}" -ne 43 ]]; then
    printf '%s: setup did not propagate Grafana dashboard apply failure (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  printf '%s: setup propagates Grafana dashboard apply failures\n' "${lab}"

  set +e
  output="$(MOCK_CLUSTERS="${cluster}" MOCK_RELEASES=$'prometheus\ngrafana' "${setup}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 1 ]]; then
    printf '%s: setup did not stop for legacy releases (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  assert_contains "${output}" "Found legacy standalone Helm release(s): prometheus grafana. Setup will not remove them."
  assert_not_contains "${output}" "helm upgrade --install monitoring"
  printf '%s: setup protects legacy standalone releases\n' "${lab}"
done

printf 'All lab lifecycle checks passed.\n'