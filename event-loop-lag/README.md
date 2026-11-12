# Lab: Node.js event-loop lag

The `/work` handler performs a bounded synchronous busy loop on Node's single event loop. Its duration defaults to 100 ms and is capped at 250 ms. Fastify's metrics plugin exposes default Node.js runtime metrics, including event-loop delay, as well as route duration metrics.

Initialize this lab's isolated kind cluster and install `kube-prometheus-stack`, KEDA (including its CRDs), and cAdvisor:

```sh
./event-loop-lag/setup.sh
```

The setup script is safe to rerun and does not install this lab's application. It creates or reuses `metrics-event-loop-lag`, using the `kind-metrics-event-loop-lag` context. The app, ScaledObject, k6 Job, and k6 ConfigMap use the dedicated `event-loop-lag` namespace; monitoring and KEDA use their own namespaces. Setup also installs the shared cAdvisor DaemonSet from `monitoring/cadvisor` and waits for its rollout. Run `./event-loop-lag/cleanup.sh` when finished with this lab; it deletes only that cluster.

Prometheus automatically scrapes cAdvisor's annotated pod at `/metrics` on port 8080, making container CPU and memory series available in Grafana Explore. The DaemonSet is bounded to 300m CPU and 256Mi memory and requires read-only access to node filesystem, cgroups, and containerd state/socket; keep it to these disposable kind clusters.

If this cluster still has the old standalone Helm releases `prometheus` or `grafana`, setup stops without removing them. The simplest migration is to run `./event-loop-lag/cleanup.sh` and then setup again; to preserve the cluster, manually uninstall each existing release from context `kind-metrics-event-loop-lag` before retrying.

Setup provisions **Workshop: application resources and k6 requests** in Grafana. After starting the app and load Job, run `kubectl --context kind-metrics-event-loop-lag port-forward -n monitoring svc/monitoring-grafana 3000:80`, open <http://localhost:3000>, and sign in as `admin`. Retrieve the chart-generated password with:

```sh
kubectl --context kind-metrics-event-loop-lag get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

This is the same command as `k get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo` when `k` is your `kubectl` alias. On macOS, use `base64 -D` instead of `base64 --decode`. Setup also prints the generated password at completion; avoid sharing or saving terminal logs that contain it. Select this lab and the current k6 run in the dashboard. It compares per-pod application-process CPU and resident memory with k6 HTTP requests per second by response status. Reload the dashboard if the new run is not listed yet; the request panel has no data before k6 samples arrive and goes empty after samples age out. Grafana's local state is ephemeral and is removed when the lab cluster is cleaned up.

If upgrading a cluster that has workloads left in the old `labs` namespace, setup does not move or delete them; they may continue running. Review and remove the old resources yourself, or run this lab's `cleanup.sh` followed by `setup.sh` to recreate the cluster.

```sh
docker build -f event-loop-lag/Dockerfile -t workshop-event-loop-lag:local .
kind load docker-image workshop-event-loop-lag:local --name metrics-event-loop-lag
kubectl --context kind-metrics-event-loop-lag apply -f event-loop-lag/kubernetes.yaml
kubectl --context kind-metrics-event-loop-lag rollout status deployment/event-loop-lag -n event-loop-lag --timeout=120s
kubectl --context kind-metrics-event-loop-lag apply -f event-loop-lag/loadgen.yaml
kubectl --context kind-metrics-event-loop-lag get hpa,scaledobjects,pods -n event-loop-lag -w
```

Inspect the framework exposition with `kubectl --context kind-metrics-event-loop-lag port-forward -n event-loop-lag svc/event-loop-lag 8080:8080` and open `http://localhost:8080/metrics`. The `ScaledObject` uses one of the runtime series and caps the Deployment at five replicas. A single bounded event-loop block can be triggered with `curl 'http://localhost:8080/work?duration=200'`.

The k6 Job runs for three minutes at 12 virtual users, with each request blocking for 100 ms. The k6 script ConfigMap is installed in the `event-loop-lag` namespace by setup. In a separate terminal, follow k6 output with `kubectl --context kind-metrics-event-loop-lag logs -n event-loop-lag job/event-loop-lag-load -f`. k6 counts HTTP 503 responses as overload and records other non-2xx statuses separately; neither stops the run. Stop it with `kubectl --context kind-metrics-event-loop-lag delete job event-loop-lag-load -n event-loop-lag --ignore-not-found`; delete the Job before reapplying its manifest if its TTL has not expired. Remove the lab service with `kubectl --context kind-metrics-event-loop-lag delete -f event-loop-lag/kubernetes.yaml`.