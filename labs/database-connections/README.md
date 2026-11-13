# Lab: Database connections

The Go service uses a GORM-managed PostgreSQL pool capped at four connections per pod. `GET /work` acquires one connection and holds it during a bounded `pg_sleep`. Gin middleware and GORM's Prometheus plugin expose request, runtime, and pool telemetry; the included PostgreSQL pod is ephemeral and capped at 256 MiB. The `/healthz` readiness endpoint checks only that the HTTP process is serving, so pool saturation cannot make Kubernetes remove a busy pod; database failures still produce `503` responses from `/work`.

This lab is an independent Go module. From the repository root, run its tests and build locally with:

```sh
(cd labs/database-connections && go test ./... && go build ./...)
```

Initialize this lab's isolated kind cluster and install `kube-prometheus-stack`, KEDA (including its CRDs), Metrics Server for the optional CPU comparison, and cAdvisor:

```sh
./labs/database-connections/scripts/setup.sh
```

The setup script is safe to rerun and does not install this lab's application. It creates or reuses `metrics-labs`, using the `kind-metrics-labs` context. The app, PostgreSQL, ScaledObject, k6 Job, and k6 ConfigMap use the dedicated `database-connections` namespace; monitoring and KEDA use their own namespaces. Setup also installs the shared cAdvisor DaemonSet from `monitoring/cadvisor` and waits for its rollout. Metrics Server is bounded to 100m CPU and 128Mi memory and uses `--kubelet-insecure-tls` for kind's self-signed kubelet certificates; keep this configuration to disposable local workshop clusters. Run `./labs/database-connections/scripts/cleanup.sh` when finished with this lab; it deletes only that cluster.

Prometheus automatically scrapes cAdvisor's annotated pod at `/metrics` on port 8080, making container CPU and memory series available in Grafana Explore. The DaemonSet is bounded to 300m CPU and 256Mi memory and requires read-only access to node filesystem, cgroups, and containerd state/socket; keep it to these disposable kind clusters.

If this cluster still has the old standalone Helm releases `prometheus` or `grafana`, setup stops without removing them. The simplest migration is to run `./labs/database-connections/scripts/cleanup.sh` and then setup again; to preserve the cluster, manually uninstall each existing release from context `kind-metrics-labs` before retrying.

Setup provisions **Workshop: application resources and k6 requests** in Grafana. After starting the app and load Job, run `./labs/database-connections/scripts/grafana-port-forward.sh` (or provide a local port, such as `./labs/database-connections/scripts/grafana-port-forward.sh 3001`) in a separate terminal; it forwards the service to `localhost:3000` by default and stays active until Ctrl-C. Open <http://localhost:3000> and sign in as `admin`. Retrieve the chart-generated password with:

```sh
kubectl --context kind-metrics-labs get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

This is the same command as `k get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo` when `k` is your `kubectl` alias. On macOS, use `base64 -D` instead of `base64 --decode`. Setup also prints the generated password at completion; avoid sharing or saving terminal logs that contain it. Select this lab in the dashboard. The database-specific panels compare pool occupancy, k6 p95 latency, process CPU against the 70% CPU-HPA target, and Prometheus-observed application pod count. CPU is an approximation based on process CPU divided by the container's 25m request; the pod count reflects scraped pods and may lag actual replicas. The request-rate panel sums concurrent runs and needs at least two samples. Grafana's local state is ephemeral and is removed when the lab cluster is cleaned up.

To pick up the KEDA metrics and kube-state-metrics changes in an existing cluster, rerun `./labs/database-connections/scripts/setup.sh`; it is safe to rerun and upgrades the Helm releases in place. To update only the dashboard, run `kubectl --context kind-metrics-labs apply -k monitoring/grafana` from the repository root, then refresh Grafana.

If upgrading a cluster that has workloads left in the legacy Kubernetes namespace `labs`, setup does not move or delete them; they may continue running. Review and remove the old resources yourself, or run this lab's `scripts/cleanup.sh` followed by `scripts/setup.sh` to recreate the cluster.

From the repository root, build and load the images if you have not already:

```sh
./labs/database-connections/scripts/build-images.sh
kubectl --context kind-metrics-labs apply -f labs/database-connections/kubernetes.yaml
kubectl --context kind-metrics-labs apply -f labs/database-connections/scaledobject.yaml
kubectl --context kind-metrics-labs rollout status deployment/postgres -n database-connections --timeout=120s
kubectl --context kind-metrics-labs rollout status deployment/database-connections -n database-connections --timeout=120s
```

The image helper uses Docker Buildx to build and load the image into this lab's kind cluster. If you rebuild an image after its Deployment is already running, restart that Deployment to make Kubernetes use the newly loaded `:local` image.

Start the staged k6 workload. It holds at 1, 3, 6, and 12 virtual users for 60, 60, 60, and 405 seconds, with 5-second ramps between levels, for a 10-minute run:

```sh
kubectl --context kind-metrics-labs apply -f labs/database-connections/loadgen.yaml
kubectl --context kind-metrics-labs get hpa,scaledobjects,pods -n database-connections -w
```

The k6 script ConfigMap is installed in the `database-connections` namespace by setup. In a separate terminal, follow the k6 output with `kubectl --context kind-metrics-labs logs -n database-connections job/database-connections-load -f`. k6 counts HTTP 503 responses as overload and records other non-2xx statuses separately; neither stops the run. The same staged workload is used in each comparison; allow time for Prometheus scrapes and HPA/KEDA polling before judging the response.

#### Compare fixed, CPU-based, and connection-based scaling

`scaledobject.yaml` is the single KEDA `ScaledObject` for this lab. It has two triggers: the connection-based Prometheus trigger (`gorm_dbstats_in_use`, threshold 2 per pod) and a CPU trigger (70% utilization). KEDA scales to whichever trigger requires more replicas, between one and five. Compare one mode at a time and never run multiple k6 Jobs concurrently. To run with a fixed single replica, remove the `ScaledObject`, wait until its HPA disappears, and reset the deployment:

```sh
kubectl --context kind-metrics-labs delete job database-connections-load -n database-connections --ignore-not-found
kubectl --context kind-metrics-labs delete scaledobject database-connections -n database-connections
kubectl --context kind-metrics-labs get hpa -n database-connections -w
kubectl --context kind-metrics-labs scale deployment/database-connections -n database-connections --replicas=1
kubectl --context kind-metrics-labs apply -f labs/database-connections/loadgen.yaml
```

Stop the HPA watch with Ctrl-C after the KEDA-created HPA is gone. For a connection-only or CPU-only comparison, first remove the `ScaledObject` as above, then apply a copy of `scaledobject.yaml` with only the trigger you want to test. Metrics Server is installed in this lab's cluster by setup. Stop any previous Job and start a fresh run:

```sh
kubectl --context kind-metrics-labs delete job database-connections-load -n database-connections --ignore-not-found
kubectl --context kind-metrics-labs scale deployment/database-connections -n database-connections --replicas=1
kubectl --context kind-metrics-labs apply -f labs/database-connections/scaledobject.yaml
kubectl --context kind-metrics-labs top pods -n database-connections
kubectl --context kind-metrics-labs apply -f labs/database-connections/loadgen.yaml
```

To return to the default combined scaling, delete any trimmed copy, reset to one replica, and reapply the merged `ScaledObject`:

```sh
kubectl --context kind-metrics-labs delete job database-connections-load -n database-connections --ignore-not-found
kubectl --context kind-metrics-labs delete scaledobject database-connections -n database-connections --ignore-not-found
kubectl --context kind-metrics-labs scale deployment/database-connections -n database-connections --replicas=1
kubectl --context kind-metrics-labs apply -f labs/database-connections/kubernetes.yaml
kubectl --context kind-metrics-labs apply -f labs/database-connections/scaledobject.yaml
kubectl --context kind-metrics-labs apply -f labs/database-connections/loadgen.yaml
```

Before each new mode, delete the prior k6 Job and wait for any old HPA to disappear. `/work` mostly waits in PostgreSQL, so CPU utilization may remain below the CPU target even as pool occupancy and latency rise; connection-based scaling is useful only while PostgreSQL has spare capacity. The CPU panel uses the Go process collector and 25m CPU request as an approximation; Kubernetes HPA measures container CPU, and the Prometheus-observed pod count is scrape-delayed rather than an exact replica count.

Inspect the framework metrics directly with `kubectl --context kind-metrics-labs port-forward -n database-connections svc/database-connections 8080:8080`, then visit `http://localhost:8080/metrics`. The `ScaledObject` selects a pool-related series from the framework exposition and caps the application at five replicas. A manual request is `curl 'http://localhost:8080/work?duration=3s'`.

Stop its load with `kubectl --context kind-metrics-labs delete job database-connections-load -n database-connections --ignore-not-found`. To repeat the job before TTL cleanup, delete it first, then apply its manifest again. Remove the scaler and lab services with `kubectl --context kind-metrics-labs delete -f labs/database-connections/scaledobject.yaml --ignore-not-found` and `kubectl --context kind-metrics-labs delete -f labs/database-connections/kubernetes.yaml`.