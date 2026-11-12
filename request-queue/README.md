# Lab: Request queue depth

Two workers each spend 1.5 seconds processing a request. Work waits in a channel capped at 32 entries; new requests are rejected with HTTP 503 when full. `request_queue_depth` counts queued (not currently executing) work, and request cancellation is propagated to workers.

Initialize this lab's isolated kind cluster and install `kube-prometheus-stack`, KEDA (including its CRDs), and cAdvisor:

```sh
./request-queue/setup.sh
```

The setup script is safe to rerun and does not install this lab's application. It creates or reuses `metrics-request-queue`, using the `kind-metrics-request-queue` context. It also installs the shared cAdvisor DaemonSet from `monitoring/cadvisor` and waits for its rollout. Run `./request-queue/cleanup.sh` when finished with this lab; it deletes only that cluster.

Prometheus automatically scrapes cAdvisor's annotated pod at `/metrics` on port 8080, making container CPU and memory series available in Grafana Explore. The DaemonSet is bounded to 300m CPU and 256Mi memory and requires read-only access to node filesystem, cgroups, and containerd state/socket; keep it to these disposable kind clusters.

If this cluster still has the old standalone Helm releases `prometheus` or `grafana`, setup stops without removing them. The simplest migration is to run `./request-queue/cleanup.sh` and then setup again; to preserve the cluster, manually uninstall each existing release from context `kind-metrics-request-queue` before retrying.

Setup provisions **Workshop: application resources and k6 requests** in Grafana. After starting the app and load Job, run `kubectl --context kind-metrics-request-queue port-forward -n monitoring svc/monitoring-grafana 3000:80`, open <http://localhost:3000>, and sign in as `admin`; retrieve the chart-generated password with `kubectl --context kind-metrics-request-queue get secret monitoring-grafana -n monitoring -o jsonpath='{.data.admin-password}' | openssl base64 -d -A`. Select this lab and the current k6 run in the dashboard. It compares per-pod application-process CPU and resident memory with k6 HTTP requests per second by response status. Reload the dashboard if the new run is not listed yet; the request panel has no data before k6 samples arrive and goes empty after samples age out. Grafana's local state is ephemeral and is removed when the lab cluster is cleaned up.

```sh
docker build -f request-queue/Dockerfile -t workshop-request-queue:local .
kind load docker-image workshop-request-queue:local --name metrics-request-queue
kubectl --context kind-metrics-request-queue apply -f request-queue/kubernetes.yaml
kubectl --context kind-metrics-request-queue rollout status deployment/request-queue -n labs --timeout=120s
kubectl --context kind-metrics-request-queue apply -f request-queue/loadgen.yaml
kubectl --context kind-metrics-request-queue get hpa,scaledobjects,pods -n labs -w
```

Prometheus query: `sum(request_queue_depth)`. KEDA uses a per-replica target of four queued requests and caps the Deployment at five replicas. To inspect metrics, run `kubectl --context kind-metrics-request-queue port-forward -n labs svc/request-queue 8080:8080`, then open `http://localhost:8080/metrics`.

The k6 Job runs for three minutes at 16 virtual users. The k6 script ConfigMap is installed in this cluster by setup. In a separate terminal, follow k6 output with `kubectl --context kind-metrics-request-queue logs -n labs job/request-queue-load -f`. k6 counts HTTP 503 responses as expected overload and records other non-2xx statuses separately; responses do not stop the run. Stop it with `kubectl --context kind-metrics-request-queue delete job request-queue-load -n labs --ignore-not-found`; delete the Job before reapplying its manifest if its TTL has not expired. Remove the lab service with `kubectl --context kind-metrics-request-queue delete -f request-queue/kubernetes.yaml`.