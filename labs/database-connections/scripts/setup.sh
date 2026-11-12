#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="database-connections"
CLUSTER_NAME="metrics-${LAB_NAME}"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
MONITORING_CHART_VERSION="93.2.2"
KEDA_CHART_VERSION="2.21.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"

printf '\n✨ Setting up the %s workshop lab ✨\n' "${LAB_NAME}"
printf '   Cluster: %s | Kubernetes context: %s\n\n' "${CLUSTER_NAME}" "${KIND_CONTEXT}"
printf '🔎 Checking required tools (kind, kubectl, and Helm)...\n'

for command_name in kind kubectl helm; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command not found on PATH: %s\n' "${command_name}" >&2
    exit 1
  fi
done

printf '\n🔍 Checking whether the dedicated kind cluster already exists...\n'
clusters="$(kind get clusters)"
cluster_exists=false
while IFS= read -r cluster; do
  if [[ "${cluster}" == "${CLUSTER_NAME}" ]]; then
    cluster_exists=true
    break
  fi
done <<< "${clusters}"

if [[ "${cluster_exists}" == false ]]; then
  printf '📦 Creating kind cluster %s...\n' "${CLUSTER_NAME}"
  kind create cluster --name "${CLUSTER_NAME}" --wait 120s
else
  printf '♻️ Reusing existing kind cluster %s.\n' "${CLUSTER_NAME}"
fi

printf '\n🔗 Verifying Kubernetes access and preparing the monitoring namespace...\n'
kubectl --context "${KIND_CONTEXT}" cluster-info >/dev/null
kubectl --context "${KIND_CONTEXT}" create namespace monitoring --dry-run=client -o yaml \
  | kubectl --context "${KIND_CONTEXT}" apply -f -
printf '\n🛡️ Checking for legacy standalone monitoring releases...\n'
legacy_releases="$(helm list --short --namespace monitoring --kube-context "${KIND_CONTEXT}")"
legacy_monitoring_releases=""
while IFS= read -r release; do
  case "${release}" in
    prometheus|grafana) legacy_monitoring_releases+=" ${release}" ;;
  esac
done <<< "${legacy_releases}"
if [[ -n "${legacy_monitoring_releases}" ]]; then
  printf 'Found legacy standalone Helm release(s):%s. Setup will not remove them. Run %s/cleanup.sh and recreate this lab cluster, or explicitly uninstall those releases from context %s before retrying.\n' \
    "${legacy_monitoring_releases}" "${SCRIPT_DIR}" "${KIND_CONTEXT}" >&2
  exit 1
fi

printf '\n📁 Preparing the dedicated %s namespace and k6 script...\n' "${LAB_NAME}"
kubectl --context "${KIND_CONTEXT}" create namespace "${LAB_NAME}" --dry-run=client -o yaml \
  | kubectl --context "${KIND_CONTEXT}" apply -f -
kubectl --context "${KIND_CONTEXT}" apply --namespace "${LAB_NAME}" -f "${ROOT_DIR}/tools/k6/configmap.yaml"

printf '\n📚 Updating Helm repositories...\n'
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add kedacore https://kedacore.github.io/charts --force-update
helm repo update prometheus-community kedacore

printf '\n📈 Installing Prometheus and Grafana with kube-prometheus-stack...\n'
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "${MONITORING_CHART_VERSION}" \
  --namespace monitoring --create-namespace \
  --values "${ROOT_DIR}/monitoring/kube-prometheus-stack-values.yaml" \
  --kube-context "${KIND_CONTEXT}" \
  --wait --timeout 5m

printf '\n⚖️ Installing KEDA and its autoscaling components...\n'
helm upgrade --install keda kedacore/keda \
  --version "${KEDA_CHART_VERSION}" \
  --namespace keda --create-namespace \
  --values "${ROOT_DIR}/monitoring/keda-values.yaml" \
  --kube-context "${KIND_CONTEXT}" \
  --wait --timeout 5m

printf '\n⏳ Waiting for KEDA, Prometheus, and Grafana to become ready...\n'
kubectl --context "${KIND_CONTEXT}" wait --for=condition=Established --timeout=120s \
  crd/cloudeventsources.eventing.keda.sh \
  crd/clustercloudeventsources.eventing.keda.sh \
  crd/clustertriggerauthentications.keda.sh \
  crd/scaledjobs.keda.sh \
  crd/scaledobjects.keda.sh \
  crd/triggerauthentications.keda.sh

kubectl --context "${KIND_CONTEXT}" wait --for=condition=Established --timeout=120s \
  crd/prometheuses.monitoring.coreos.com \
  crd/servicemonitors.monitoring.coreos.com
kubectl --context "${KIND_CONTEXT}" rollout status deployment/monitoring-kube-prometheus-operator -n monitoring --timeout=180s
prometheus_statefulset="prometheus-monitoring-kube-prometheus-prometheus"
prometheus_statefulset_found=false
for attempt in {1..90}; do
  if [[ -n "$(kubectl --context "${KIND_CONTEXT}" get statefulset "${prometheus_statefulset}" -n monitoring --ignore-not-found -o name)" ]]; then
    prometheus_statefulset_found=true
    break
  fi
  sleep 2
done
if [[ "${prometheus_statefulset_found}" == false ]]; then
  printf 'Prometheus Operator did not create StatefulSet %s within 180 seconds.\n' "${prometheus_statefulset}" >&2
  exit 1
fi
kubectl --context "${KIND_CONTEXT}" rollout status "statefulset/${prometheus_statefulset}" -n monitoring --timeout=180s
kubectl --context "${KIND_CONTEXT}" rollout status deployment/monitoring-grafana -n monitoring --timeout=180s
kubectl --context "${KIND_CONTEXT}" rollout status deployment/keda-operator -n keda --timeout=180s
kubectl --context "${KIND_CONTEXT}" rollout status deployment/keda-operator-metrics-apiserver -n keda --timeout=180s
kubectl --context "${KIND_CONTEXT}" rollout status deployment/keda-admission-webhooks -n keda --timeout=180s

printf '\n📊 Installing cAdvisor and the Grafana workshop dashboard...\n'
kubectl --context "${KIND_CONTEXT}" apply -k "${ROOT_DIR}/monitoring/cadvisor"
kubectl --context "${KIND_CONTEXT}" rollout status daemonset/cadvisor -n monitoring --timeout=180s
kubectl --context "${KIND_CONTEXT}" apply -k "${ROOT_DIR}/monitoring/grafana"

printf '\n✅ Cluster %s is ready with Prometheus, Grafana, KEDA, cAdvisor, and the workshop dashboard.\n' "${CLUSTER_NAME}"
printf 'Lab resources and the k6 ConfigMap use namespace %s. Existing workloads in namespace labs are not moved or removed.\n' "${LAB_NAME}"
printf '\n🛠️ Run Docker Buildx to build and load the application image(s) before applying kubernetes.yaml:\n'
printf '   %s/scripts/build-images.sh\n' "${LAB_DIR}"
printf '📊 To open Grafana at http://localhost:3000, run %s/scripts/grafana-port-forward.sh [local-port] in another terminal.\n' "${LAB_DIR}"
printf '   The optional local port defaults to 3000; keep it running and press Ctrl-C to stop forwarding.\n'

if [[ "$(uname -s)" == "Darwin" ]]; then
  BASE64_DECODE_FLAG="-D"
  BASE64_DECODE_COMMAND="base64 -D"
else
  BASE64_DECODE_FLAG="--decode"
  BASE64_DECODE_COMMAND="base64 --decode"
fi

printf '\n🔐 Retrieving the generated Grafana admin password...\n'
if ! grafana_password_encoded="$(kubectl --context "${KIND_CONTEXT}" get secret -n monitoring monitoring-grafana -o jsonpath='{.data.admin-password}')"; then
  printf '❌ Could not retrieve the Grafana admin password from context %s.\n' "${KIND_CONTEXT}" >&2
  exit 1
fi
if [[ -z "${grafana_password_encoded}" ]]; then
  printf '❌ The Grafana admin-password secret is empty in context %s.\n' "${KIND_CONTEXT}" >&2
  exit 1
fi
if [[ ! "${grafana_password_encoded}" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]]; then
  printf '❌ Could not decode the Grafana admin password: the secret is not valid base64.\n' >&2
  exit 1
fi
if ! grafana_password="$(printf '%s' "${grafana_password_encoded}" | base64 "${BASE64_DECODE_FLAG}")"; then
  printf '❌ Could not decode the Grafana admin password returned by context %s.\n' "${KIND_CONTEXT}" >&2
  exit 1
fi
if [[ -z "${grafana_password}" ]]; then
  printf '❌ The decoded Grafana admin password is empty.\n' >&2
  exit 1
fi

printf '⚠️ The password will be printed below; avoid sharing or saving logs that contain it.\n'
printf '👤 Grafana username: admin\n'
printf '💡 Retrieve it later with:\nkubectl --context %s get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | %s; echo\n' \
  "${KIND_CONTEXT}" "${BASE64_DECODE_COMMAND}"
printf '🔑 Grafana admin password: %s\n' "${grafana_password}"