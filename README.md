# Resource-pressure autoscaling labs

Five small services demonstrate bounded resource pressure. Three use framework-provided telemetry with multiple runtime and request-level series, so students can inspect the data and identify which signal is relevant to each scenario:

- [Database connections](database-connections/README.md)
- [File descriptors](file-descriptors/README.md)
- [Request queue](request-queue/README.md)
- [HTTP client pool wait](http-client-pool/README.md)
- [Event-loop lag](event-loop-lag/README.md)

The applications, load jobs, pool/queue/descriptor sizes, CPU and memory limits, and replica ceilings are intentionally bounded. Run **one lab at a time** on a small host. The database lab includes a single ephemeral PostgreSQL pod. The `kube-prometheus-stack` Prometheus retains only one day of local data; Grafana uses ephemeral storage and is removed with its lab cluster.

## Prerequisites

- Docker, `kind`, `kubectl`, and Helm installed and available on `PATH`.
- A machine able to run a single-node kind cluster, Prometheus, Grafana, KEDA, and one lab at a time.
- Go 1.24+ to run tests or build locally; Node.js 22.19+ to run the event-loop lab locally. Docker builds use the versions in the lab Dockerfiles.

## Initialize one lab

```sh
./database-connections/setup.sh
```

Choose a lab and run only its setup script; students do not need to initialize all five. Each script creates or reuses an isolated kind cluster named `metrics-<lab-directory>` (for example, `metrics-database-connections`) and installs the pinned `kube-prometheus-stack` and KEDA Helm charts, KEDA CRDs, the k6 ConfigMap, the cAdvisor DaemonSet, and a Grafana dashboard ConfigMap into that cluster. The stack provisions Grafana with its Prometheus service as the default datasource. Setup is safe to rerun and does not deploy the lab application or load job. The resulting context is `kind-metrics-<lab-directory>`; scripts and documented `kubectl` commands explicitly target it. Run one lab at a time on a resource-constrained machine. Prometheus discovers pods annotated with `prometheus.io/scrape: "true"`; KEDA queries it at `http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090`.

cAdvisor is installed from the local Kustomize configuration at `monitoring/cadvisor`. It exposes container CPU and memory series at `/metrics`, which Prometheus scrapes through the same pod annotations. In Grafana Explore, try `container_memory_working_set_bytes{container_label_io_kubernetes_pod_namespace="labs"}` or `rate(container_cpu_usage_seconds_total{container_label_io_kubernetes_pod_namespace="labs"}[5m])` to compare lab containers. The DaemonSet has bounded resources and read-only mounts for the node filesystem, cgroups, and containerd state/socket; those host mounts still expose sensitive node metadata, so this configuration is intended for disposable local workshop clusters, not production or multi-tenant clusters.

If an existing lab cluster still has the previous standalone Helm releases named `prometheus` or `grafana`, setup stops and leaves them untouched. The simplest migration is to run that lab's `cleanup.sh` and then its `setup.sh`; to keep the cluster, manually uninstall each existing release in that lab's context before rerunning setup.

## Compare metrics in Grafana

Forward Grafana's local-only service to port 3000, replacing the example context with the selected lab's context:

```sh
kubectl --context kind-metrics-database-connections port-forward -n monitoring svc/monitoring-grafana 3000:80
```

Open <http://localhost:3000> and sign in as `admin`. Retrieve the chart-generated password in another terminal with:

```sh
kubectl --context kind-metrics-database-connections get secret monitoring-grafana -n monitoring -o jsonpath='{.data.admin-password}' | openssl base64 -d -A
```

After deploying the selected application and starting its k6 Job, open **Dashboards → Workshop: application resources and k6 requests**. Select the lab and the current k6 run in the dashboard variables. It plots application-process CPU and resident memory per pod alongside k6 HTTP requests per second, grouped by response status; the run ID comes from the unique k6 Job pod UID. Reload the dashboard if a newly started run is not yet listed. The request panel is empty before k6 sends samples and becomes empty again after the run's samples age out; k6 sends stale markers when it ends. Prometheus retains one day of data and Grafana's local state is ephemeral. In **Explore**, the provisioned **Prometheus** datasource remains available for other queries.

## Build and load the selected lab

Follow the selected lab's README for its image build/load commands and expected observations. The Go labs use Gin metrics middleware, and the database lab also uses GORM's Prometheus plugin; the Node.js lab uses Fastify's metrics plugin. These integrations expose runtime, request, and framework metrics alongside the workload telemetry. Each lab cluster gets its own copy of the pinned official `grafana/k6` workload ConfigMap from setup; no custom load-generator image is needed. To change the script, edit the `config.js` value in `tools/k6/configmap.yaml` and apply it to the selected cluster using that lab's context.

## Observe scaling

Use the selected lab's README for commands to deploy its `kubernetes.yaml` and separate `loadgen.yaml` Job. Every lab's commands name its own context, `kind-metrics-<lab-directory>`. Each k6 Job uses 12 or 16 bounded virtual users, a 15-second request timeout, and connection reuse disabled so fresh requests can be distributed as replicas change. Runs last three minutes except the database lab, which runs for ten minutes. k6 reports successful, HTTP 503 overload, and other unexpected responses separately; these responses are recorded without stopping the run. The same run streams `k6_http_reqs_total` to Prometheus remote write for the Grafana request-rate panel.

```sh
kubectl --context kind-metrics-database-connections get pods -n labs -w
kubectl --context kind-metrics-database-connections get hpa,scaledobjects -n labs -w
```

Run the watch commands in separate terminals. In the example above, follow k6 output with `kubectl --context kind-metrics-database-connections logs -n labs job/database-connections-load -f`; use the equivalent context and Job name for another lab. In a separate terminal, run `kubectl --context kind-metrics-database-connections port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090`, then open <http://localhost:9090> and query that lab's metric. You can also port-forward the lab service (see its README) to inspect `/metrics`. Scaling is asynchronous: allow at least a few Prometheus scrapes and KEDA polling intervals for scale-up; scale-down is intentionally stabilized for 60 seconds.

## Cleanup

When finished with the selected lab, its cleanup script deletes only that lab's entire isolated cluster, including its workloads and monitoring components:

```sh
./database-connections/cleanup.sh
```

For a different lab, run that lab directory's `cleanup.sh`. These scripts do not touch the other lab clusters, the older `metrics-labs` cluster, the separate `metrics-lab` cluster, or any non-kind cluster.