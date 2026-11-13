# Lab: Node.js event-loop lag

The `/work` handler performs a bounded synchronous busy loop on Node's single event loop. Its duration defaults to 100 ms and is capped at 250 ms. Fastify's metrics plugin exposes default Node.js runtime metrics, including event-loop delay, as well as route duration metrics.

Initialize this lab's isolated kind cluster and install `kube-prometheus-stack`, KEDA (including its CRDs), and cAdvisor:

```sh
./labs/event-loop-lag/scripts/setup.sh
```

The setup script is safe to rerun and does not install this lab's application. It creates or reuses the shared `metrics-labs` cluster, using the `kind-metrics-labs` context. The app, ScaledObject, k6 Job, and k6 ConfigMap use the dedicated `event-loop-lag` namespace; monitoring and KEDA use their own namespaces. Setup also installs the shared cAdvisor DaemonSet from `monitoring/cadvisor` and waits for its rollout. Run `./labs/event-loop-lag/scripts/cleanup.sh` when finished with this lab; it deletes only the `event-loop-lag` namespace and leaves the shared cluster and monitoring stack running.

Prometheus automatically scrapes cAdvisor's annotated pod at `/metrics` on port 8080, making container CPU and memory series available in Grafana Explore. The DaemonSet is bounded to 300m CPU and 256Mi memory and requires read-only access to node filesystem, cgroups, and containerd state/socket; keep it to these disposable kind clusters.

If this cluster still has the old standalone Helm releases `prometheus` or `grafana`, setup stops without removing them. Uninstall each existing release from context `kind-metrics-labs` before retrying, then rerun setup.

Setup provisions **Workshop: application resources and k6 requests** in Grafana. After starting the app and load Job, run `./labs/event-loop-lag/scripts/grafana-port-forward.sh` in a separate terminal; it forwards the service to `localhost:3000` by default and stays active until Ctrl-C. Open <http://localhost:3000> and sign in as `admin`. Retrieve the chart-generated password with:

```sh
kubectl --context kind-metrics-labs get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

On macOS, use `base64 -D` instead of `base64 --decode`. Setup also prints the generated password at completion; avoid sharing or saving terminal logs that contain it. Select this lab in the dashboard. It compares per-pod application-process resident memory against its 100 MiB scaling target, alongside k6 HTTP requests per second by response status, summing concurrent runs. The request panel needs at least two k6 samples to calculate a rate. Grafana's local state is ephemeral and is removed when the lab namespace is cleaned up.

To pick up the KEDA and dashboard changes in an existing cluster, rerun `./labs/event-loop-lag/scripts/setup.sh`, or run `kubectl --context kind-metrics-labs apply -k monitoring/grafana` from the repository root to update only the dashboard, then refresh Grafana.

If upgrading a cluster that has workloads left in the legacy Kubernetes namespace `labs`, setup does not move or delete them; they may continue running. Review them and delete that namespace yourself with `kubectl --context kind-metrics-labs delete namespace labs` once nothing there is still needed.

From the repository root, build and load the image, then deploy the app and its ScaledObject:

```sh
./labs/event-loop-lag/scripts/build-images.sh
kubectl --context kind-metrics-labs apply -f labs/event-loop-lag/kubernetes.yaml
kubectl --context kind-metrics-labs apply -f labs/event-loop-lag/scaledobject.yaml
kubectl --context kind-metrics-labs rollout status deployment/event-loop-lag -n event-loop-lag --timeout=120s
kubectl --context kind-metrics-labs apply -f labs/event-loop-lag/loadgen.yaml
kubectl --context kind-metrics-labs get hpa,scaledobjects,pods -n event-loop-lag -w
```

Inspect the framework exposition with `kubectl --context kind-metrics-labs port-forward -n event-loop-lag svc/event-loop-lag 8080:8080` and open `http://localhost:8080/metrics`. The `ScaledObject` has two triggers, event-loop lag and resident memory per replica, and caps the Deployment at five replicas; KEDA scales to whichever trigger requires more replicas. A single bounded event-loop block can be triggered with `curl 'http://localhost:8080/work?duration=200'`.

The k6 Job runs a 10-minute staged ramp (1, 3, 6, then 12 virtual users, with 5-second transitions), with each request blocking the event loop for 100 ms. The k6 script ConfigMap is installed in the `event-loop-lag` namespace by setup. In a separate terminal, follow k6 output with `kubectl --context kind-metrics-labs logs -n event-loop-lag job/event-loop-lag-load -f`. k6 counts HTTP 503 responses as overload and records other non-2xx statuses separately; neither stops the run. Stop it with `kubectl --context kind-metrics-labs delete job event-loop-lag-load -n event-loop-lag --ignore-not-found`; delete the Job before reapplying its manifest if its TTL has not expired. Remove the lab resources with `kubectl --context kind-metrics-labs delete -f labs/event-loop-lag/scaledobject.yaml --ignore-not-found` and `kubectl --context kind-metrics-labs delete -f labs/event-loop-lag/kubernetes.yaml`.
