# Resource-pressure autoscaling labs

Three small services demonstrate bounded resource pressure. They use framework-provided telemetry with multiple runtime and request-level series, so students can inspect the data and identify which signal is relevant to each scenario:

- [Database connections](labs/database-connections/README.md)
- [File descriptors](labs/file-descriptors/README.md)
- [Event-loop lag](labs/event-loop-lag/README.md)

The applications, load jobs, pool/queue/descriptor sizes, CPU and memory limits, and replica ceilings are intentionally bounded. Run **one lab at a time** on a small host. The database lab includes a single ephemeral PostgreSQL pod. The `kube-prometheus-stack` Prometheus retains only one day of local data; Grafana uses ephemeral storage and is removed with its lab cluster.

## Prerequisites

- Docker, `kind`, `kubectl`, and Helm installed and available on `PATH`.
- A machine able to run a single-node kind cluster, Prometheus, Grafana, KEDA, and one lab at a time.
- Go 1.24+ to run tests or build locally; Node.js 22.19+ to run the event-loop lab locally. Docker builds use the versions in the lab Dockerfiles.

## Initialize one lab

```sh
./labs/database-connections/scripts/setup.sh
```

Choose one of the three labs under `labs/` and run only its setup script; students do not need to initialize all three. Each script creates or reuses an isolated kind cluster named `metrics-<lab-directory>` (for example, `metrics-database-connections`) and installs the pinned `kube-prometheus-stack` and KEDA Helm charts, KEDA CRDs, the k6 ConfigMap, the cAdvisor DaemonSet, and a Grafana dashboard ConfigMap into that cluster. The database lab also installs a bounded Metrics Server so its optional CPU-HPA comparison is available. Each lab's application, ScaledObject, k6 Job, and k6 ConfigMap use a dedicated namespace matching the lab directory (`database-connections`, `file-descriptors`, or `event-loop-lag`); monitoring and KEDA remain in `monitoring` and `keda`. The stack provisions Grafana with its Prometheus service as the default datasource. Setup is safe to rerun and does not deploy the lab application or load job. The resulting context is `kind-metrics-<lab-directory>`; scripts and documented `kubectl` commands explicitly target it. Run one lab at a time on a resource-constrained machine. Prometheus discovers pods annotated with `prometheus.io/scrape: "true"`; KEDA queries it at `http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090`.

cAdvisor is installed from the local Kustomize configuration at `monitoring/cadvisor`. It exposes container CPU and memory series at `/metrics`, which Prometheus scrapes through the same pod annotations. In Grafana Explore, try `container_memory_working_set_bytes{container_label_io_kubernetes_pod_namespace="database-connections"}` or `rate(container_cpu_usage_seconds_total{container_label_io_kubernetes_pod_namespace="database-connections"}[5m])` to compare lab containers (replace the namespace with the selected lab). The DaemonSet has bounded resources and read-only mounts for the node filesystem, cgroups, and containerd state/socket; those host mounts still expose sensitive node metadata, so this configuration is intended for disposable local workshop clusters, not production or multi-tenant clusters.

If an existing lab cluster still has the previous standalone Helm releases named `prometheus` or `grafana`, setup stops and leaves them untouched. The simplest migration is to run that lab's `scripts/cleanup.sh` and then its `scripts/setup.sh`; to keep the cluster, manually uninstall each existing release in that lab's context before rerunning setup.

When reusing a cluster from an earlier version of the workshop, workloads already in the legacy Kubernetes namespace `labs` are not moved or deleted by setup and may continue running. Review and remove those old lab resources yourself, or use that lab's `scripts/cleanup.sh` and `scripts/setup.sh` to recreate its isolated cluster.

## Compare metrics in Grafana

Forward Grafana's local-only service to port 3000 with the selected lab's `scripts/grafana-port-forward.sh`; for a different local port, pass it as the optional first argument (for example, `3001`). The helper stays in the foreground until Ctrl-C:

```sh
./labs/database-connections/scripts/grafana-port-forward.sh
```

Open <http://localhost:3000> and sign in as `admin`. Retrieve the chart-generated password in another terminal with:

```sh
kubectl --context kind-metrics-database-connections get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

This is the same command as `k get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo` when `k` is your `kubectl` alias. On macOS, use `base64 -D` instead of `base64 --decode`.

The selected lab's setup script also prints the generated admin password when setup completes. Treat that output as a secret: avoid sharing or saving terminal logs that contain it.

After deploying the selected application and starting its k6 Job, open **Dashboards → Workshop: application resources and k6 requests** and select the lab. It plots application-process CPU and resident memory per pod alongside k6 HTTP requests per second, grouped by response status. For the database lab it also shows pool occupancy, k6 p95 latency, process CPU compared with the CPU-HPA target, and Prometheus-observed pod count. Concurrent k6 runs in the same lab are summed; past runs remain visible in the selected time range. The request panel needs at least two k6 samples to calculate a rate; k6 sends stale markers when it ends. Prometheus retains one day of data and Grafana's local state is ephemeral. In **Explore**, the provisioned **Prometheus** datasource remains available for other queries.

For an existing cluster, apply the updated dashboard from the repository root, replacing the context with the selected lab's context, then refresh Grafana:

```sh
kubectl --context kind-metrics-database-connections apply -k monitoring/grafana
```

## Build and load the selected lab

From the repository root, run the selected lab's `scripts/build-images.sh` after setup to build its local image with Docker Buildx and load it into that lab's kind cluster. This is separate from setup so students can rebuild without reinstalling cluster components. The Go labs use Gin metrics middleware, and the database lab also uses GORM's Prometheus plugin; the Node.js lab uses Fastify's metrics plugin. These integrations expose runtime, request, and framework metrics alongside the workload telemetry. Each lab cluster gets its own copy of the pinned official `grafana/k6` workload ConfigMap from setup; no custom load-generator image is needed. To change the script, edit the `config.js` value in `tools/k6/configmap.yaml` and apply it with that lab's context and namespace, for example: `kubectl --context kind-metrics-database-connections apply -n database-connections -f tools/k6/configmap.yaml`.

## Run Go checks locally

Each Go lab is an independent module with its own `go.mod` and `go.sum`. Run its tests and build from the repository root with:

```sh
(cd labs/database-connections && go test ./... && go build ./...)
(cd labs/file-descriptors && go test ./... && go build ./...)
```

## Observe scaling

Use the selected lab's README for commands to deploy its `kubernetes.yaml` and separate `loadgen.yaml` Job. Every lab's commands name its own context, `kind-metrics-<lab-directory>`. Each k6 Job uses bounded virtual users, a 15-second request timeout, and connection reuse disabled so fresh requests can be distributed as replicas change. Most runs last three minutes; the database lab ramps through 1, 3, 6, and 12 users with 90-second plateaus and 10-second transitions (about 6 minutes 30 seconds total). k6 reports successful, HTTP 503 overload, and other unexpected responses separately; these responses are recorded without stopping the run. The same run streams request counts and latency metrics to Prometheus remote write. The database README describes repeatable fixed-replica, CPU-HPA, and connection-based KEDA comparisons; run only one scaler and one k6 Job at a time.

```sh
kubectl --context kind-metrics-database-connections get pods -n database-connections -w
kubectl --context kind-metrics-database-connections get hpa,scaledobjects -n database-connections -w
```

Run the watch commands in separate terminals. In the example above, follow k6 output with `kubectl --context kind-metrics-database-connections logs -n database-connections job/database-connections-load -f`; use the corresponding lab namespace, context, and Job name for another lab. In a separate terminal, run `kubectl --context kind-metrics-database-connections port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090`, then open <http://localhost:9090> and query that lab's metric. You can also port-forward the lab service (see its README) to inspect `/metrics`. Scaling is asynchronous: allow at least a few Prometheus scrapes and KEDA polling intervals for scale-up; scale-down is intentionally stabilized for 60 seconds.

## Cleanup

When finished with the selected lab, its cleanup script deletes only that lab's entire isolated cluster, including its workloads and monitoring components:

```sh
./labs/database-connections/scripts/cleanup.sh
```

For a different lab, run that lab directory's `scripts/cleanup.sh`. These scripts do not touch the other lab clusters, the older `metrics-labs` cluster, the separate `metrics-lab` cluster, or any non-kind cluster.