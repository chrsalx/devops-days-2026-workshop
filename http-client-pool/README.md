# Lab: HTTP client connection-pool wait

The Go front end can hold at most two outbound connections to a slow, local Go upstream per pod. It instruments the waiters before connection acquisition as `http_client_pool_waiters` (and also exports cumulative wait time as `http_client_pool_wait_seconds_total`). A bounded admission limit prevents an unbounded number of waiting handler requests.

Initialize this lab's isolated kind cluster and install `kube-prometheus-stack`, KEDA (including its CRDs), and cAdvisor:

```sh
./http-client-pool/setup.sh
```

The setup script is safe to rerun and does not install this lab's application. It creates or reuses `metrics-http-client-pool`, using the `kind-metrics-http-client-pool` context. The app, upstream, ScaledObject, k6 Job, and k6 ConfigMap use the dedicated `http-client-pool` namespace; monitoring and KEDA use their own namespaces. Setup also installs the shared cAdvisor DaemonSet from `monitoring/cadvisor` and waits for its rollout. Run `./http-client-pool/cleanup.sh` when finished with this lab; it deletes only that cluster.

Prometheus automatically scrapes cAdvisor's annotated pod at `/metrics` on port 8080, making container CPU and memory series available in Grafana Explore. The DaemonSet is bounded to 300m CPU and 256Mi memory and requires read-only access to node filesystem, cgroups, and containerd state/socket; keep it to these disposable kind clusters.

If this cluster still has the old standalone Helm releases `prometheus` or `grafana`, setup stops without removing them. The simplest migration is to run `./http-client-pool/cleanup.sh` and then setup again; to preserve the cluster, manually uninstall each existing release from context `kind-metrics-http-client-pool` before retrying.

Setup provisions **Workshop: application resources and k6 requests** in Grafana. After starting the app and load Job, run `kubectl --context kind-metrics-http-client-pool port-forward -n monitoring svc/monitoring-grafana 3000:80`, open <http://localhost:3000>, and sign in as `admin`. Retrieve the chart-generated password with:

```sh
kubectl --context kind-metrics-http-client-pool get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

This is the same command as `k get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo` when `k` is your `kubectl` alias. On macOS, use `base64 -D` instead of `base64 --decode`. Setup also prints the generated password at completion; avoid sharing or saving terminal logs that contain it. Select this lab and the current k6 run in the dashboard. It compares per-pod application-process CPU and resident memory with k6 HTTP requests per second by response status. Reload the dashboard if the new run is not listed yet; the request panel has no data before k6 samples arrive and goes empty after samples age out. Grafana's local state is ephemeral and is removed when the lab cluster is cleaned up.

If upgrading a cluster that has workloads left in the old `labs` namespace, setup does not move or delete them; they may continue running. Review and remove the old resources yourself, or run this lab's `cleanup.sh` followed by `setup.sh` to recreate the cluster.

```sh
docker build -f http-client-pool/Dockerfile -t workshop-http-client-pool:local .
docker build -f http-client-pool/Dockerfile.upstream -t workshop-http-upstream:local .
kind load docker-image workshop-http-client-pool:local workshop-http-upstream:local --name metrics-http-client-pool
kubectl --context kind-metrics-http-client-pool apply -f http-client-pool/kubernetes.yaml
kubectl --context kind-metrics-http-client-pool rollout status deployment/http-client-upstream -n http-client-pool --timeout=120s
kubectl --context kind-metrics-http-client-pool rollout status deployment/http-client-pool -n http-client-pool --timeout=120s
kubectl --context kind-metrics-http-client-pool apply -f http-client-pool/loadgen.yaml
kubectl --context kind-metrics-http-client-pool get hpa,scaledobjects,pods -n http-client-pool -w
```

Prometheus query: `sum(http_client_pool_waiters{namespace="http-client-pool", pod=~"http-client-pool-.*"})`. KEDA uses a per-replica target of one waiter and caps the front end at five replicas. The k6 Job runs for three minutes at 12 virtual users and makes each upstream request take two seconds. The k6 script ConfigMap is installed in the `http-client-pool` namespace by setup. In a separate terminal, follow k6 output with `kubectl --context kind-metrics-http-client-pool logs -n http-client-pool job/http-client-pool-load -f`. k6 counts HTTP 503 responses as overload and records other non-2xx statuses separately; neither stops the run. Inspect the gauge with `kubectl --context kind-metrics-http-client-pool port-forward -n http-client-pool svc/http-client-pool 8080:8080` and `http://localhost:8080/metrics`.

Stop the load with `kubectl --context kind-metrics-http-client-pool delete job http-client-pool-load -n http-client-pool --ignore-not-found`; delete the Job before reapplying its manifest if its TTL has not expired. Remove the lab services with `kubectl --context kind-metrics-http-client-pool delete -f http-client-pool/kubernetes.yaml`.