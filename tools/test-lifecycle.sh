#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
LABS=(database-connections file-descriptors event-loop-lag)

kind() {
  printf 'kind %s\n' "$*" >&2
  if [[ "$*" == "get clusters" ]]; then
    printf '%s\n' "${MOCK_CLUSTERS:-}"
  fi
  if [[ -n "${MOCK_KIND_FAIL:-}" && "$*" == *"${MOCK_KIND_FAIL}"* ]]; then
    return 45
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
  if [[ "$*" == *"get secret -n monitoring monitoring-grafana"* ]]; then
    printf '%s' "${MOCK_GRAFANA_PASSWORD_B64-c2VjdXJlLXRlc3QtcGFzc3dvcmQ=}"
  fi
}

helm() {
  printf 'helm %s\n' "$*" >&2
  if [[ "$*" == "list --short --namespace monitoring --kube-context "* ]]; then
    printf '%s\n' "${MOCK_RELEASES:-}"
    return 0
  fi
  if [[ -n "${MOCK_HELM_FAIL:-}" && "$*" == *"${MOCK_HELM_FAIL}"* ]]; then
    return 42
  fi
}

docker() {
  printf 'docker %s\n' "$*" >&2
  if [[ "$*" == "info --format {{.OSType}}/{{.Architecture}}" ]]; then
    printf 'linux/amd64\n'
  fi
  if [[ -n "${MOCK_DOCKER_FAIL:-}" && "$*" == *"${MOCK_DOCKER_FAIL}"* ]]; then
    return 44
  fi
}

export -f kind kubectl helm docker

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
metrics-event-loop-lag"

for lab in "${LABS[@]}"; do
  cluster="metrics-${lab}"
  context="kind-${cluster}"
  setup="${ROOT_DIR}/labs/${lab}/scripts/setup.sh"
  cleanup="${ROOT_DIR}/labs/${lab}/scripts/cleanup.sh"
  build_images="${ROOT_DIR}/labs/${lab}/scripts/build-images.sh"
  grafana_forward="${ROOT_DIR}/labs/${lab}/scripts/grafana-port-forward.sh"

  output="$(MOCK_CLUSTERS="${all_clusters}" "${setup}" 2>&1)"
  assert_contains "${output}" "✨ Setting up the ${lab} workshop lab ✨"
  assert_contains "${output}" "🔎 Checking required tools (kind, kubectl, and Helm)..."
  assert_contains "${output}" "📈 Installing Prometheus and Grafana with kube-prometheus-stack..."
  assert_contains "${output}" "⚖️ Installing KEDA and its autoscaling components..."
  assert_contains "${output}" "📊 Installing cAdvisor and the Grafana workshop dashboard..."
  assert_contains "${output}" "✅ Cluster ${cluster} is ready"
  assert_contains "${output}" "kubectl --context ${context} cluster-info"
  assert_contains "${output}" "kubectl --context ${context} create namespace monitoring --dry-run=client -o yaml"
  assert_contains "${output}" "helm list --short --namespace monitoring --kube-context ${context}"
  assert_contains "${output}" "kubectl --context ${context} create namespace ${lab} --dry-run=client -o yaml"
  assert_contains "${output}" "kubectl --context ${context} apply --namespace ${lab} -f ${ROOT_DIR}/tools/k6/configmap.yaml"
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
  assert_contains "${output}" "Lab resources and the k6 ConfigMap use namespace ${lab}. Existing workloads in namespace labs are not moved or removed."
  assert_contains "${output}" "🛠️ Run Docker Buildx to build and load the application image(s) before applying kubernetes.yaml:"
  assert_contains "${output}" "${build_images}"
  assert_contains "${output}" "📊 To open Grafana at http://localhost:3000, run ${grafana_forward} [local-port] in another terminal."
  assert_contains "${output}" "The optional local port defaults to 3000; keep it running and press Ctrl-C to stop forwarding."
  assert_contains "${output}" "kubectl --context ${context} get secret -n monitoring monitoring-grafana -o jsonpath={.data.admin-password}"
  assert_contains "${output}" "🔑 Grafana admin password: secure-test-password"
  assert_contains "${output}" "💡 Retrieve it later with:"
  assert_contains "${output}" "⚠️ The password will be printed below; avoid sharing or saving logs that contain it."
  if [[ "${output}" != *$'\n🔑 Grafana admin password: secure-test-password' ]]; then
    printf '%s: password was not the final setup output\n' "${lab}" >&2
    exit 1
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    assert_contains "${output}" "| base64 -D; echo"
  else
    assert_contains "${output}" "| base64 --decode; echo"
  fi
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

  output="$(MOCK_CLUSTERS="${cluster}" "${build_images}" 2>&1)"
  assert_contains "${output}" "docker buildx build --platform linux/amd64 --load --file ${ROOT_DIR}/labs/${lab}/Dockerfile --tag workshop-${lab}:local ${ROOT_DIR}"
  if [[ "${lab}" == "http-client-pool" ]]; then
    assert_contains "${output}" "docker buildx build --platform linux/amd64 --load --file ${ROOT_DIR}/${lab}/Dockerfile.upstream --tag workshop-http-upstream:local ${ROOT_DIR}"
    assert_contains "${output}" "kind load docker-image workshop-http-client-pool:local workshop-http-upstream:local --name ${cluster}"
  else
    assert_contains "${output}" "kind load docker-image workshop-${lab}:local --name ${cluster}"
  fi
  printf '%s: Buildx images load into the dedicated cluster\n' "${lab}"

  set +e
  output="$(MOCK_CLUSTERS="" "${build_images}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 1 ]]; then
    printf '%s: image helper accepted a missing cluster (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  assert_contains "${output}" "Kind cluster ${cluster} does not exist"
  assert_not_contains "${output}" "docker buildx build"
  printf '%s: image helper requires its cluster before building\n' "${lab}"

  set +e
  output="$(MOCK_CLUSTERS="${cluster}" MOCK_DOCKER_FAIL="buildx build" "${build_images}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 44 ]]; then
    printf '%s: image helper did not propagate Buildx failure (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  assert_not_contains "${output}" "kind load docker-image"
  printf '%s: image helper stops on Buildx failure\n' "${lab}"

  set +e
  output="$(MOCK_CLUSTERS="${cluster}" MOCK_KIND_FAIL="load docker-image" "${build_images}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 45 ]]; then
    printf '%s: image helper did not propagate kind load failure (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  printf '%s: image helper propagates kind load failures\n' "${lab}"

  output="$(MOCK_CLUSTERS="${cluster}" "${grafana_forward}" 2>&1)"
  assert_contains "${output}" "kubectl --context ${context} port-forward -n monitoring svc/monitoring-grafana 3000:80"
  output="$(MOCK_CLUSTERS="${cluster}" "${grafana_forward}" 3300 2>&1)"
  assert_contains "${output}" "kubectl --context ${context} port-forward -n monitoring svc/monitoring-grafana 3300:80"
  output="$(MOCK_CLUSTERS="${cluster}" "${grafana_forward}" 003300 2>&1)"
  assert_contains "${output}" "kubectl --context ${context} port-forward -n monitoring svc/monitoring-grafana 3300:80"
  printf '%s: Grafana forwarding uses the lab context and optional local port\n' "${lab}"

  for invalid_port in 0 65536 abc 000000000000000000000000000000; do
    set +e
    output="$(MOCK_CLUSTERS="${cluster}" "${grafana_forward}" "${invalid_port}" 2>&1)"
    status=$?
    set -e
    if [[ "${status}" -ne 2 ]]; then
      printf '%s: Grafana forwarder accepted invalid port %s (status %s)\n' "${lab}" "${invalid_port}" "${status}" >&2
      exit 1
    fi
  done
  printf '%s: Grafana forwarder rejects invalid ports\n' "${lab}"

  set +e
  output="$(MOCK_CLUSTERS="${cluster}" MOCK_KUBECTL_FAIL="port-forward -n monitoring" "${grafana_forward}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 43 ]]; then
    printf '%s: Grafana forwarder did not propagate kubectl failure (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  printf '%s: Grafana forwarder propagates kubectl failures\n' "${lab}"

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
  MOCK_CLUSTERS="${cluster}" MOCK_KUBECTL_FAIL="apply --namespace ${lab} -f ${ROOT_DIR}/tools/k6/configmap.yaml" \
    "${setup}" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "${status}" -ne 43 ]]; then
    printf '%s: setup did not propagate k6 ConfigMap apply failure (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  printf '%s: setup propagates k6 ConfigMap apply failures\n' "${lab}"

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

  set +e
  output="$(MOCK_CLUSTERS="${cluster}" MOCK_KUBECTL_FAIL="get secret -n monitoring monitoring-grafana" \
    "${setup}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 1 ]]; then
    printf '%s: setup did not report Grafana secret retrieval failure (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  assert_contains "${output}" "Could not retrieve the Grafana admin password"
  printf '%s: setup reports Grafana secret retrieval failures\n' "${lab}"

  set +e
  output="$(MOCK_CLUSTERS="${cluster}" MOCK_GRAFANA_PASSWORD_B64="" "${setup}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 1 ]]; then
    printf '%s: setup accepted an empty Grafana secret (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  assert_contains "${output}" "The Grafana admin-password secret is empty"
  printf '%s: setup rejects an empty Grafana secret\n' "${lab}"

  set +e
  output="$(MOCK_CLUSTERS="${cluster}" MOCK_GRAFANA_PASSWORD_B64="not-base64!" "${setup}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 1 ]]; then
    printf '%s: setup accepted malformed Grafana password data (status %s)\n' "${lab}" "${status}" >&2
    exit 1
  fi
  assert_contains "${output}" "Could not decode the Grafana admin password"
  printf '%s: setup rejects malformed Grafana password data\n' "${lab}"
done

printf 'All lab lifecycle checks passed.\n'