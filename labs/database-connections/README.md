# Lab: Database connections

The Go service uses a GORM-managed PostgreSQL pool capped at four connections per pod. `GET /work` acquires one connection and holds it during a bounded `pg_sleep`. Gin middleware and GORM's Prometheus plugin expose request, runtime, and pool telemetry; the included PostgreSQL pod is ephemeral and capped at 256 MiB.

This lab is an independent Go module. From the repository root, run its tests and build locally with:

```sh
(cd labs/database-connections && go test ./... && go build ./...)
```

Initialize this lab's isolated kind cluster and install `kube-prometheus-stack`, KEDA (including its CRDs), and cAdvisor:

```sh
./labs/database-connections/scripts/setup.sh
```

The setup script is safe to rerun and does not install this lab's application. It creates or reuses `metrics-database-connections`, using the `kind-metrics-database-connections` context. The app, PostgreSQL, ScaledObject, k6 Job, and k6 ConfigMap use the dedicated `database-connections` namespace; monitoring and KEDA use their own namespaces. Setup also installs the shared cAdvisor DaemonSet from `monitoring/cadvisor` and waits for its rollout. Run `./labs/database-connections/scripts/cleanup.sh` when finished with this lab; it deletes only that cluster.

Prometheus automatically scrapes cAdvisor's annotated pod at `/metrics` on port 8080, making container CPU and memory series available in Grafana Explore. The DaemonSet is bounded to 300m CPU and 256Mi memory and requires read-only access to node filesystem, cgroups, and containerd state/socket; keep it to these disposable kind clusters.

If this cluster still has the old standalone Helm releases `prometheus` or `grafana`, setup stops without removing them. The simplest migration is to run `./labs/database-connections/scripts/cleanup.sh` and then setup again; to preserve the cluster, manually uninstall each existing release from context `kind-metrics-database-connections` before retrying.

Setup provisions **Workshop: application resources and k6 requests** in Grafana. After starting the app and load Job, run `./labs/database-connections/scripts/grafana-port-forward.sh` (or provide a local port, such as `./labs/database-connections/scripts/grafana-port-forward.sh 3001`) in a separate terminal; it forwards the service to `localhost:3000` by default and stays active until Ctrl-C. Open <http://localhost:3000> and sign in as `admin`. Retrieve the chart-generated password with:

```sh
kubectl --context kind-metrics-database-connections get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

This is the same command as `k get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo` when `k` is your `kubectl` alias. On macOS, use `base64 -D` instead of `base64 --decode`. Setup also prints the generated password at completion; avoid sharing or saving terminal logs that contain it. Select this lab and the current k6 run in the dashboard. It compares per-pod application-process CPU and resident memory with k6 HTTP requests per second by response status. Reload the dashboard if the new run is not listed yet; the request panel has no data before k6 samples arrive and goes empty after samples age out. Grafana's local state is ephemeral and is removed when the lab cluster is cleaned up.

If upgrading a cluster that has workloads left in the legacy Kubernetes namespace `labs`, setup does not move or delete them; they may continue running. Review and remove the old resources yourself, or run this lab's `scripts/cleanup.sh` followed by `scripts/setup.sh` to recreate the cluster.

From the repository root, build and load the images if you have not already:

```sh
./labs/database-connections/scripts/build-images.sh
kubectl --context kind-metrics-database-connections apply -f labs/database-connections/kubernetes.yaml
kubectl --context kind-metrics-database-connections rollout status deployment/postgres -n database-connections --timeout=120s
kubectl --context kind-metrics-database-connections rollout status deployment/database-connections -n database-connections --timeout=120s
```

The image helper uses Docker Buildx to build and load the image into this lab's kind cluster. If you rebuild an image after its Deployment is already running, restart that Deployment to make Kubernetes use the newly loaded `:local` image.

Start the ten-minute k6 load (12 virtual users) and inspect scaling and the run summary:

```sh
kubectl --context kind-metrics-database-connections apply -f labs/database-connections/loadgen.yaml
kubectl --context kind-metrics-database-connections get hpa,scaledobjects,pods -n database-connections -w
```

The k6 script ConfigMap is installed in the `database-connections` namespace by setup. In a separate terminal, follow the k6 output with `kubectl --context kind-metrics-database-connections logs -n database-connections job/database-connections-load -f`. k6 counts HTTP 503 responses as overload and records other non-2xx statuses separately; neither stops the run.

Inspect the framework metrics directly with `kubectl --context kind-metrics-database-connections port-forward -n database-connections svc/database-connections 8080:8080`, then visit `http://localhost:8080/metrics`. The `ScaledObject` selects a pool-related series from the framework exposition and caps the application at five replicas. A manual request is `curl 'http://localhost:8080/work?duration=3s'`.

Stop its load with `kubectl --context kind-metrics-database-connections delete job database-connections-load -n database-connections --ignore-not-found`. To repeat the job before TTL cleanup, delete it first, then apply its manifest again. Remove the lab services with `kubectl --context kind-metrics-database-connections delete -f labs/database-connections/kubernetes.yaml`.