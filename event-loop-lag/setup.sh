#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="event-loop-lag"
CLUSTER_NAME="metrics-${LAB_NAME}"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
MONITORING_CHART_VERSION="93.2.2"
KEDA_CHART_VERSION="2.21.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

for command_name in kind kubectl helm; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command not found on PATH: %s\n' "${command_name}" >&2
    exit 1
  fi
done

clusters="$(kind get clusters)"
cluster_exists=false
while IFS= read -r cluster; do
  if [[ "${cluster}" == "${CLUSTER_NAME}" ]]; then
    cluster_exists=true
    break
  fi
done <<< "${clusters}"

if [[ "${cluster_exists}" == false ]]; then
  kind create cluster --name "${CLUSTER_NAME}" --wait 120s
fi

kubectl --context "${KIND_CONTEXT}" cluster-info >/dev/null
kubectl --context "${KIND_CONTEXT}" create namespace monitoring --dry-run=client -o yaml \
  | kubectl --context "${KIND_CONTEXT}" apply -f -
legacy_releases="$(helm list --all --short --namespace monitoring --kube-context "${KIND_CONTEXT}")"
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

kubectl --context "${KIND_CONTEXT}" create namespace labs --dry-run=client -o yaml \
  | kubectl --context "${KIND_CONTEXT}" apply -f -
kubectl --context "${KIND_CONTEXT}" apply -f "${ROOT_DIR}/tools/k6/configmap.yaml"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add kedacore https://kedacore.github.io/charts --force-update
helm repo update prometheus-community kedacore

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "${MONITORING_CHART_VERSION}" \
  --namespace monitoring --create-namespace \
  --values "${ROOT_DIR}/monitoring/kube-prometheus-stack-values.yaml" \
  --kube-context "${KIND_CONTEXT}" \
  --wait --timeout 5m

helm upgrade --install keda kedacore/keda \
  --version "${KEDA_CHART_VERSION}" \
  --namespace keda --create-namespace \
  --values "${ROOT_DIR}/monitoring/keda-values.yaml" \
  --kube-context "${KIND_CONTEXT}" \
  --wait --timeout 5m

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
kubectl --context "${KIND_CONTEXT}" apply -k "${ROOT_DIR}/monitoring/cadvisor"
kubectl --context "${KIND_CONTEXT}" rollout status daemonset/cadvisor -n monitoring --timeout=180s
kubectl --context "${KIND_CONTEXT}" apply -k "${ROOT_DIR}/monitoring/grafana"

printf 'Cluster %s is ready with kube-prometheus-stack, KEDA, cAdvisor, and the Grafana workshop dashboard.\n' "${CLUSTER_NAME}"