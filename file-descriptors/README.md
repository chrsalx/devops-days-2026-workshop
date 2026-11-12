# Lab: File descriptors

Each `GET /work` opens up to eight real `/dev/null` descriptors and closes them when the request completes or is canceled. A 64-slot semaphore bounds all open descriptors per pod. Gin middleware and the Prometheus Go client's process collector expose request, runtime, and process telemetry, including the container's open descriptors and baseline handles.

Initialize this lab's isolated kind cluster and install `kube-prometheus-stack`, KEDA (including its CRDs), and cAdvisor:

```sh
./file-descriptors/setup.sh
```

The setup script is safe to rerun and does not install this lab's application. It creates or reuses `metrics-file-descriptors`, using the `kind-metrics-file-descriptors` context. It also installs the shared cAdvisor DaemonSet from `monitoring/cadvisor` and waits for its rollout. Run `./file-descriptors/cleanup.sh` when finished with this lab; it deletes only that cluster.

Prometheus automatically scrapes cAdvisor's annotated pod at `/metrics` on port 8080, making container CPU and memory series available in Grafana Explore. The DaemonSet is bounded to 300m CPU and 256Mi memory and requires read-only access to node filesystem, cgroups, and containerd state/socket; keep it to these disposable kind clusters.

If this cluster still has the old standalone Helm releases `prometheus` or `grafana`, setup stops without removing them. The simplest migration is to run `./file-descriptors/cleanup.sh` and then setup again; to preserve the cluster, manually uninstall each existing release from context `kind-metrics-file-descriptors` before retrying.

Setup provisions **Workshop: application resources and k6 requests** in Grafana. After starting the app and load Job, run `kubectl --context kind-metrics-file-descriptors port-forward -n monitoring svc/monitoring-grafana 3000:80`, open <http://localhost:3000>, and sign in as `admin`; retrieve the chart-generated password with `kubectl --context kind-metrics-file-descriptors get secret monitoring-grafana -n monitoring -o jsonpath='{.data.admin-password}' | openssl base64 -d -A`. Select this lab and the current k6 run in the dashboard. It compares per-pod application-process CPU and resident memory with k6 HTTP requests per second by response status. Reload the dashboard if the new run is not listed yet; the request panel has no data before k6 samples arrive and goes empty after samples age out. Grafana's local state is ephemeral and is removed when the lab cluster is cleaned up.

```sh
docker build -f file-descriptors/Dockerfile -t workshop-file-descriptors:local .
kind load docker-image workshop-file-descriptors:local --name metrics-file-descriptors
kubectl --context kind-metrics-file-descriptors apply -f file-descriptors/kubernetes.yaml
kubectl --context kind-metrics-file-descriptors rollout status deployment/file-descriptors -n labs --timeout=120s
kubectl --context kind-metrics-file-descriptors apply -f file-descriptors/loadgen.yaml
kubectl --context kind-metrics-file-descriptors get hpa,scaledobjects,pods -n labs -w
```

Inspect the framework exposition with `kubectl --context kind-metrics-file-descriptors port-forward -n labs svc/file-descriptors 8080:8080`, then open `http://localhost:8080/metrics`. The process-level descriptor total includes baseline sockets and runtime handles, while each request can add up to eight bounded descriptors; the `ScaledObject` caps the Deployment at five replicas. A manual request is `curl 'http://localhost:8080/work?count=8&duration=3s'`.

The k6 Job runs for three minutes at 12 virtual users, opening four descriptors per request. The k6 script ConfigMap is installed in this cluster by setup. In a separate terminal, follow k6 output with `kubectl --context kind-metrics-file-descriptors logs -n labs job/file-descriptors-load -f`. k6 counts HTTP 503 responses as overload and records other non-2xx statuses separately; neither stops the run. Stop it with `kubectl --context kind-metrics-file-descriptors delete job file-descriptors-load -n labs --ignore-not-found`; delete the Job before reapplying its manifest if its TTL has not expired. Remove the lab service with `kubectl --context kind-metrics-file-descriptors delete -f file-descriptors/kubernetes.yaml`.